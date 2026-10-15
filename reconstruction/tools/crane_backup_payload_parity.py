#!/usr/bin/env python3
"""G-11 C2: READ-ONLY ZIP payload and metadata parity (not authenticity).

Compare a disposable original reference .cranect/.cranebk against an offline
synthetic candidate, matching app/container IDs IN MEMORY but never emitting
them. No extraction, writes, Keychain reads, file names, digests or raw errors
in output. All non-Keychain data is read with a 256 MiB PER-ARCHIVE budget
and ZIP CRC validation before SHA-256 comparison.

Matching synthetic archives NEVER proves genuine Crane interoperability.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any
import zipfile

from crane_backup_inspector import (
    InvalidArchive, UnsupportedArchive, MAX_PLIST_BYTES,
    MAX_VERIFY_BYTES, VERIFY_CHUNK_BYTES, inspect_archive,
)
from crane_backup_shape_compare import ComparisonUnavailable, compare_archives


class ParityUnavailable(Exception):
    """An input cannot be compared safely or reproducibly."""


SPECIAL = frozenset(("Info.plist", "Metadata.plist", "Keychain.plist"))
MAX_CONTAINERS = 50


def _identity(value: str | os.PathLike[str]) -> tuple[int, int, int, int, int]:
    path = Path(value)
    if path.is_symlink():
        raise ParityUnavailable("input symlink")
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ParityUnavailable("input must be a regular file")
    return (metadata.st_dev, metadata.st_ino, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns)


def _member_digest(zf: zipfile.ZipFile, info: zipfile.ZipInfo,
                   limit: int) -> bytes:
    if info.file_size > limit:
        raise UnsupportedArchive("comparison budget exceeded")
    length = 0
    digest = hashlib.sha256()
    with zf.open(info, "r") as stream:
        while True:
            part = stream.read(VERIFY_CHUNK_BYTES)
            if not part:
                break
            length += len(part)
            if length > info.file_size:
                raise ParityUnavailable("uncompressed size changed")
            digest.update(part)
    if length != info.file_size:
        raise ParityUnavailable("uncompressed size mismatch")
    return digest.digest()


def _indexes(info: dict[str, Any],
             zf: zipfile.ZipFile) -> tuple[dict[tuple[str, str], dict[str, zipfile.ZipInfo]],
                                        dict[tuple[str, str], dict[str, zipfile.ZipInfo]],
                                        dict[tuple[str, str], dict[str, zipfile.ZipInfo]]]:
    """Internal per-container payload, directory and plist indexes.

    The caller never serializes the identifiers or ZIP member names.
    """
    payload: dict[tuple[str, str], dict[str, zipfile.ZipInfo]] = {}
    folders: dict[tuple[str, str], dict[str, zipfile.ZipInfo]] = {}
    metadata: dict[tuple[str, str], dict[str, zipfile.ZipInfo]] = {}
    members = zf.infolist()
    for record in info["containers"]:
        identity = (record["application_identifier"],
                    record["container_identifier"])
        prefix = (identity[0] + "/" + identity[1] + "/"
                  if info["kind"] == "multi" else "")
        data: dict[str, zipfile.ZipInfo] = {}
        dirs: dict[str, zipfile.ZipInfo] = {}
        plists: dict[str, zipfile.ZipInfo] = {}
        for item in members:
            if not item.filename.startswith(prefix):
                continue
            relative = item.filename[len(prefix):].rstrip("/")
            if relative in SPECIAL:
                if relative != "Keychain.plist":
                    plists[relative] = item
                continue
            if item.is_dir():
                dirs[relative] = item
            else:
                data[relative] = item
        payload[identity] = data
        folders[identity] = dirs
        metadata[identity] = plists
    return payload, folders, metadata


def compare_payloads(reference: str | os.PathLike[str],
                     candidate: str | os.PathLike[str]) -> dict[str, Any]:
    before_ref = _identity(reference)
    before_candidate = _identity(candidate)
    if before_ref[:2] == before_candidate[:2]:
        raise ParityUnavailable("one archive compared to itself")

    # Require bounded, independent CRC checks before a digest can be called
    # verified. Keychain contents remain unopened by the inspector and us.
    ref = inspect_archive(reference, verify_payload=True)
    cand = inspect_archive(candidate, verify_payload=True)
    if len(ref["containers"]) > MAX_CONTAINERS or len(cand["containers"]) > MAX_CONTAINERS:
        raise UnsupportedArchive("comparison has too many containers")

    identities_ref = {
        (r["application_identifier"], r["container_identifier"])
        for r in ref["containers"]
    }
    identities_candidate = {
        (r["application_identifier"], r["container_identifier"])
        for r in cand["containers"]
    }
    if ref["kind"] != cand["kind"] or identities_ref != identities_candidate:
        return {
            "status": "container_identity_or_kind_mismatch_uncompared",
            "comparison_completed": False,
            "reference_container_count": len(identities_ref),
            "candidate_container_count": len(identities_candidate),
            "keychain_contents_read": False,
            "files_extracted": False,
            "filesystem_writes": False,
            "original_compatibility_proven": False,
            "restore_safe": False,
        }

    counters = {
        "compared_file_count": 0,
        "reference_file_count": 0,
        "candidate_file_count": 0,
        "missing_candidate_files": 0,
        "extra_candidate_files": 0,
        "file_size_mismatches": 0,
        "equal_size_content_mismatches": 0,
        "missing_candidate_directories": 0,
        "extra_candidate_directories": 0,
        "missing_candidate_plists": 0,
        "extra_candidate_plists": 0,
        "different_plist_bytes": 0,
        "keychain_entries_not_compared": sum(
            int(item["has_keychain"]) for item in
            (ref["containers"] + cand["containers"])),
    }
    # Different compression methods or known metadata keys also matter even
    # if the extracted bytes happen to agree.
    profile = compare_archives(reference, candidate, verify_payload=False)
    with zipfile.ZipFile(reference, "r") as first, zipfile.ZipFile(candidate, "r") as second:
        ref_files, ref_dirs, ref_plists = _indexes(ref, first)
        candidate_files, candidate_dirs, candidate_plists = _indexes(cand, second)
        for identity in sorted(identities_ref):
            first_payload = ref_files[identity]
            second_payload = candidate_files[identity]
            counters["reference_file_count"] += len(first_payload)
            counters["candidate_file_count"] += len(second_payload)
            ref_names = set(first_payload)
            cand_names = set(second_payload)
            counters["missing_candidate_files"] += len(ref_names - cand_names)
            counters["extra_candidate_files"] += len(cand_names - ref_names)
            counters["missing_candidate_directories"] += len(
                set(ref_dirs[identity]) - set(candidate_dirs[identity]))
            counters["extra_candidate_directories"] += len(
                set(candidate_dirs[identity]) - set(ref_dirs[identity]))
            for name in sorted(ref_names & cand_names):
                left, right = first_payload[name], second_payload[name]
                if left.file_size != right.file_size:
                    counters["file_size_mismatches"] += 1
                    continue
                if (_member_digest(first, left, MAX_VERIFY_BYTES) !=
                        _member_digest(second, right, MAX_VERIFY_BYTES)):
                    counters["equal_size_content_mismatches"] += 1
                counters["compared_file_count"] += 1

            left_meta = ref_plists[identity]
            right_meta = candidate_plists[identity]
            left_names, right_names = set(left_meta), set(right_meta)
            counters["missing_candidate_plists"] += len(left_names - right_names)
            counters["extra_candidate_plists"] += len(right_names - left_names)
            for name in sorted(left_names & right_names):
                left, right = left_meta[name], right_meta[name]
                if (_member_digest(first, left, MAX_PLIST_BYTES) !=
                        _member_digest(second, right, MAX_PLIST_BYTES)):
                    counters["different_plist_bytes"] += 1

        if ref["kind"] == "multi":
            root_one, root_two = first.getinfo("Info.plist"), second.getinfo("Info.plist")
            if (_member_digest(first, root_one, MAX_PLIST_BYTES) !=
                    _member_digest(second, root_two, MAX_PLIST_BYTES)):
                counters["different_plist_bytes"] += 1

    if (_identity(reference) != before_ref or
            _identity(candidate) != before_candidate):
        raise ParityUnavailable("input changed during comparison")

    all_file_differences = (
        counters["missing_candidate_files"] +
        counters["extra_candidate_files"] +
        counters["file_size_mismatches"] +
        counters["equal_size_content_mismatches"] +
        counters["missing_candidate_directories"] +
        counters["extra_candidate_directories"]
    )
    all_differences = (all_file_differences + counters["missing_candidate_plists"] +
                       counters["extra_candidate_plists"] +
                       counters["different_plist_bytes"] + profile["difference_count"])
    return {
        "status": ("payload_and_metadata_bytes_match_not_proven"
                   if all_differences == 0 else
                   "payload_or_metadata_differences"),
        **counters,
        "shape_difference_count": profile["difference_count"],
        "payload_tree_equal": all_file_differences == 0,
        "metadata_serialized_bytes_equal":
            counters["different_plist_bytes"] == 0 and
            counters["missing_candidate_plists"] == 0 and
            counters["extra_candidate_plists"] == 0,
        "comparison_completed": True,
        "crc_checked_both_non_keychain": True,
        "keychain_contents_read": False,
        "files_extracted": False,
        "filesystem_writes": False,
        "original_compatibility_proven": False,
        "restore_safe": False,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Read-only bounded SHA-256 parity check between disposable ZIPs; "
        "never a Crane originality/restore proof"))
    parser.add_argument("--reference", required=True)
    parser.add_argument("--candidate", required=True)
    args = parser.parse_args(argv)
    try:
        result = compare_payloads(args.reference, args.candidate)
        exit_code = (0 if result["status"] ==
                     "payload_and_metadata_bytes_match_not_proven" else 1)
    except (ParityUnavailable, ComparisonUnavailable, InvalidArchive,
            UnsupportedArchive, OSError, ValueError, TypeError, EOFError,
            RuntimeError, zipfile.BadZipFile):
        # No raw exception text: member names and metadata are private.
        result = {"status": "parity_unavailable_or_unsupported",
                  "original_compatibility_proven": False,
                  "restore_safe": False}
        exit_code = 2
    print(json.dumps(result, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
