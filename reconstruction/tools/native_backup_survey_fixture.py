#!/usr/bin/env python3
"""N1 native ZIP survey fixture set: synthetic app-only ZIPs, no private files."""
import argparse
import io
from pathlib import Path
import plistlib
import struct
import warnings
import zipfile

from native_backup_reader_fixture import INFO, NoSeek


def _member(name, data, *, is_symlink=False):
    item = zipfile.ZipInfo(name)
    item.create_system = 3 if is_symlink else 19
    item.compress_type = zipfile.ZIP_STORED if name.endswith("/") else zipfile.ZIP_DEFLATED
    if is_symlink:
        item.external_attr = 0o120777 << 16
    elif name.endswith("/"):
        item.external_attr = 0o40755 << 16
    else:
        item.external_attr = 0o100600 << 16
    return item, data


def build(*, wrong_path=False, duplicate=False, symlink=False,
          omit_metadata=False, with_keychain=False, stored_payload=False,
          large_payload=False) -> bytes:
    output = NoSeek()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(output, "w", allowZip64=True) as z:
            info = zipfile.ZipInfo("Info.plist")
            info.create_system = 19
            info.compress_type = zipfile.ZIP_DEFLATED
            with z.open(info, "w", force_zip64=True) as stream:
                stream.write(plistlib.dumps(INFO, fmt=plistlib.FMT_BINARY))
            records = [
                _member("com.example.crane.native/", b""),
                _member("com.example.crane.native/one.txt",
                        bytes(range(256)) * 420 if large_payload else b"FAKE_NOT_PRIVATE"),
            ]
            if stored_payload:
                records[1][0].compress_type = zipfile.ZIP_STORED
            if wrong_path:
                records.append(_member("com.example.crane.native/../escape.txt", b"bad"))
            if duplicate:
                records.append(_member("com.example.crane.native/one.txt", b"repeat"))
            if symlink:
                records.append(_member("com.example.crane.native/link.txt",
                                       b"/private/target", is_symlink=True))
            if with_keychain:
                records.append(_member("Keychain.plist", b"SYNTHETIC_TEST_ONLY"))
            for item, data in records:
                z.writestr(item, data)
            if not omit_metadata:
                z.writestr(_member("Metadata.plist",
                                  plistlib.dumps({"stub": {}},
                                                 fmt=plistlib.FMT_BINARY))[0],
                           plistlib.dumps({"stub": {}}, fmt=plistlib.FMT_BINARY))
    return output.data.getvalue()


def central_offset(content: bytes) -> int:
    eocd = content.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise ValueError("missing EOCD")
    return struct.unpack_from("<I", content, eocd + 16)[0]


def corrupted_local_name(content: bytes) -> bytes:
    result = bytearray(content)
    # First local header's Info.plist begins at byte 30.
    assert result[30:40] == b"Info.plist"
    result[30] = ord("X")
    return bytes(result)


def corrupted_central_method(content: bytes) -> bytes:
    result = bytearray(content)
    at = central_offset(content)
    assert result[at:at+4] == b"PK\x01\x02"
    struct.pack_into("<H", result, at+10, 0)
    return bytes(result)


def corrupted_descriptor(content: bytes) -> bytes:
    result = bytearray(content)
    at = content.find(b"PK\x07\x08")
    if at < 0:
        raise ValueError("missing descriptor")
    result[at+4] ^= 1
    return bytes(result)


def corrupted_member_bytes(content: bytes, member_name: str) -> bytes:
    """Tamper only a member's compressed payload; leave ZIP headers intact."""
    with zipfile.ZipFile(io.BytesIO(content), "r") as archive:
        member = archive.getinfo(member_name)
    result = bytearray(content)
    local = member.header_offset
    assert result[local:local+4] == b"PK\x03\x04"
    filename_len, extra_len = struct.unpack_from("<HH", result, local+26)
    start = local + 30 + filename_len + extra_len
    if member.compress_size < 3:
        raise ValueError("synthetic payload unexpectedly too small")
    result[start + member.compress_size // 2] ^= 0x40
    return bytes(result)


def create(folder: Path) -> list[Path]:
    if not folder.is_dir():
        raise ValueError("output directory must already exist")
    valid = build()
    variants = {
        "crane-survey-valid.cranect": valid,
        "crane-survey-traversal.cranect": build(wrong_path=True),
        "crane-survey-duplicate.cranect": build(duplicate=True),
        "crane-survey-symlink.cranect": build(symlink=True),
        "crane-survey-missing-meta.cranect": build(omit_metadata=True),
        "crane-survey-local-mismatch.cranect": corrupted_local_name(valid),
        "crane-survey-central-mismatch.cranect": corrupted_central_method(valid),
        "crane-survey-descriptor-mismatch.cranect": corrupted_descriptor(valid),
        "crane-survey-keychain-shape.cranect": build(with_keychain=True),
        "crane-survey-payload-corrupt.cranect": corrupted_member_bytes(
            valid, "com.example.crane.native/one.txt"),
        "crane-survey-keychain-corrupt.cranect": corrupted_member_bytes(
            build(with_keychain=True), "Keychain.plist"),
        "crane-survey-large-payload.cranect": build(large_payload=True),
        "crane-survey-stored-payload.cranect": build(stored_payload=True),
    }
    result = []
    for name, data in variants.items():
        p = folder / name
        if p.is_symlink():
            raise ValueError("target cannot be symlink")
        with p.open("xb") as stream:
            stream.write(data)
        result.append(p)
    return result


if __name__ == "__main__":
    cli = argparse.ArgumentParser()
    cli.add_argument("--output-dir", required=True)
    args = cli.parse_args()
    for file in create(Path(args.output_dir)):
        print(file.name)
