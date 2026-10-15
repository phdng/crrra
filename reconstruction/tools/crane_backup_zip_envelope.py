#!/usr/bin/env python3
"""G-11 C5: read-only ZIP envelope evidence from original Crane-shaped archives.

Only fixed ZIP header statistics and metadata-position booleans leave the
process; private member names/IDs, file contents, Keychain and extra bytes
never do. A structural match is NEVER proof of original Crane compatibility.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import stat
import struct
import sys
import zipfile

from crane_backup_inspector import InvalidArchive, UnsupportedArchive, inspect_archive

MAX_EXTRA_LENGTH = 65535


class EnvelopeUnavailable(Exception):
    """ZIP envelope cannot be classified under the safe inspector contract."""


def _extra_fields(value: bytes) -> tuple[int, int, int]:
    """Return number of ZIP64 16-byte extras and other/invalid extra entries."""
    if len(value) > MAX_EXTRA_LENGTH:
        raise EnvelopeUnavailable("invalid ZIP extra size")
    position = 0
    zip64_16 = 0
    other = 0
    while position < len(value):
        if len(value) - position < 4:
            raise EnvelopeUnavailable("truncated extra header")
        ident, length = struct.unpack_from("<HH", value, position)
        position += 4
        if length > len(value) - position:
            raise EnvelopeUnavailable("truncated ZIP extra data")
        if ident == 1 and length == 16:
            zip64_16 += 1
        else:
            other += 1
        position += length
    return zip64_16, other, position


def zip_envelope_profile(path: str | Path) -> dict:
    input_path = Path(path)
    if input_path.is_symlink() or not input_path.is_file():
        raise EnvelopeUnavailable("not an independent regular ZIP")
    before = input_path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise EnvelopeUnavailable("not a regular input file")
    inspected = inspect_archive(input_path, verify_payload=False)
    if inspected["kind"] != "single":
        raise EnvelopeUnavailable("only a genuine single reference is known")
    with zipfile.ZipFile(input_path, mode="r") as zf:
        entries = zf.infolist()
        if not entries:
            raise EnvelopeUnavailable("empty ZIP")
        first = entries[0].filename == "Info.plist"
        last = entries[-1].filename == "Metadata.plist"
        directories = [entry for entry in entries if entry.is_dir()]
        files = [entry for entry in entries if not entry.is_dir()]
        zip64_16_count = 0
        other_extra_count = 0
        for entry in entries:
            z64, other, _ = _extra_fields(entry.extra)
            zip64_16_count += z64
            other_extra_count += other
        all_entries = len(entries)
        version45 = sum(x.extract_version == 45 for x in entries)
        system19 = sum(x.create_system == 19 for x in entries)
        flags_808 = sum(x.flag_bits == 0x0808 for x in entries)
        result = {
            "status": "zip_envelope_observed_not_original_parity",
            "kind": "single",
            "total_entries": all_entries,
            "files": len(files),
            "directories": len(directories),
            "info_first": first,
            "metadata_last": last,
            "directories_stored": all(x.compress_type == 0
                                       for x in directories),
            "files_deflated": all(x.compress_type == 8 for x in files),
            "macos_creator_19_entries": system19,
            "general_flag_0808_entries": flags_808,
            "zip64_16_extra_entries": zip64_16_count,
            "other_extra_fields": other_extra_count,
            "requires_zip64_version_45_entries": version45,
            "all_macos_creator_19": system19 == all_entries,
            "all_general_flag_0808": flags_808 == all_entries,
            "all_zip64_16_extra": zip64_16_count == all_entries,
            "all_requires_zip64_version_45": version45 == all_entries,
            "original_compatibility_proven": False,
            "restore_safe": False,
            "app_payload_read": False,
            "keychain_contents_read": False,
            "filesystem_writes": False,
        }
    after = input_path.stat()
    identity = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, key) != getattr(after, key) for key in identity):
        raise EnvelopeUnavailable("source changed during envelope scan")
    return result


def compare_envelopes(reference: str | Path, candidate: str | Path) -> dict:
    if Path(reference).resolve(strict=True) == Path(candidate).resolve(strict=True):
        raise EnvelopeUnavailable("cannot compare an input with itself")
    left = zip_envelope_profile(reference)
    right = zip_envelope_profile(candidate)
    feature_names = (
        "info_first", "metadata_last", "directories_stored", "files_deflated",
        "all_macos_creator_19", "all_general_flag_0808",
        "all_zip64_16_extra", "all_requires_zip64_version_45",
    )
    different = [field for field in feature_names if left[field] != right[field]]
    return {
        "status": ("zip_envelope_features_match_not_proven" if not different
                   else "zip_envelope_features_differ"),
        "different_feature_names": different,
        "difference_count": len(different),
        "reference_entries": left["total_entries"],
        "candidate_entries": right["total_entries"],
        "original_compatibility_proven": False,
        "restore_safe": False,
        "app_payload_read": False,
        "keychain_contents_read": False,
        "filesystem_writes": False,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Read-only original vs synthetic ZIP envelope (headers only, no file content)"))
    parser.add_argument("--reference", required=True)
    parser.add_argument("--candidate", help="optional independent synthetic ZIP")
    args = parser.parse_args(argv)
    try:
        if args.candidate:
            if Path(args.reference).resolve(strict=True) == Path(
                    args.candidate).resolve(strict=True):
                raise EnvelopeUnavailable("cannot compare same archive")
            report = compare_envelopes(args.reference, args.candidate)
            code = 0 if report["difference_count"] == 0 else 1
        else:
            report = zip_envelope_profile(args.reference)
            code = 0
    except (EnvelopeUnavailable, InvalidArchive, UnsupportedArchive,
            ValueError, KeyError, RuntimeError, TypeError, OSError,
            zipfile.BadZipFile, EOFError, OverflowError, RecursionError):
        report = {"status": "zip_envelope_unavailable_or_invalid",
                  "original_compatibility_proven": False, "restore_safe": False,
                  "filesystem_writes": False}
        code = 2
    print(json.dumps(report, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
