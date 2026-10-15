#!/usr/bin/env python3
"""G-11 Stage C: read-only, privacy-preserving archive shape comparison.

The --reference file should eventually be a disposable-app original Crane
backup, while --candidate is output from the OFFLINE fixture writer. This tool
does not determine byte-level fidelity, restore safety, or archive authenticity.

No archive extraction, no filesystem writes, no app/Keychain payload reads.
Optional --verify-payload checks non-Keychain ZIP CRC within inspector budget.
JSON never exposes member names, bundle/container IDs, originalPaths or values.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import plistlib
import sys
from typing import Any
import zipfile

from crane_backup_inspector import (
    InvalidArchive, UnsupportedArchive, MAX_PLIST_BYTES, inspect_archive,
)
from crane_backup_metadata import WRITABLE_FILE_ATTRIBUTES

KNOWN_INFO_KEYS = frozenset({
    "applicationIdentifier", "containerIdentifier", "containerName",
    "deviceIdentifierForVendor", "originalPaths", "originalPath",
    "applicationGroups",
})
KNOWN_METADATA_KEYS = WRITABLE_FILE_ATTRIBUTES
MAX_CONTAINERS = 50


class ComparisonUnavailable(Exception):
    """Cannot compare structural profiles safely."""


def _keys_signature(document: dict, allowlist: frozenset[str]) -> dict[str, Any]:
    # Only allowlisted fixed field names reach output. Other keys contribute
    # counts, never their text or values.
    return {
        "known_fields": sorted(x for x in document if x in allowlist),
        "unrecognized_field_count": sum(x not in allowlist for x in document),
    }


def _read_plist_and_format(
    archive: zipfile.ZipFile, info: zipfile.ZipInfo,
) -> tuple[dict, str]:
    if info.file_size > MAX_PLIST_BYTES:
        raise ComparisonUnavailable("oversized metadata")
    try:
        with archive.open(info, "r") as stream:
            raw = stream.read(MAX_PLIST_BYTES + 1)
        if len(raw) > MAX_PLIST_BYTES:
            raise ComparisonUnavailable("oversized metadata")
        fmt = "binary" if raw.startswith(b"bplist00") else "xml_or_other"
        parsed = plistlib.loads(raw)
    except (OSError, EOFError, RuntimeError, ValueError, TypeError,
            OverflowError, RecursionError, zipfile.BadZipFile) as exc:
        raise ComparisonUnavailable("unreadable metadata") from exc
    if not isinstance(parsed, dict):
        raise ComparisonUnavailable("not a dictionary")
    return parsed, fmt


def _container_signature(zf: zipfile.ZipFile,
                         mapping: dict[str, zipfile.ZipInfo],
                         prefix: str) -> dict[str, Any]:
    info, fmt = _read_plist_and_format(zf, mapping[prefix + "Info.plist"])
    original_paths = info.get("originalPaths")
    if original_paths is None:
        original_paths = info.get("applicationGroups", {})
    if not isinstance(original_paths, dict):
        raise ComparisonUnavailable("malformed original paths")
    signature = {
        "info": {"format": fmt,
                 "associated_path_count": len(original_paths),
                 **_keys_signature(info, KNOWN_INFO_KEYS)},
        "metadata": {"present": False, "format": None,
                     "entry_count": 0, "known_attribute_fields": [],
                     "unrecognized_attribute_field_count": 0},
        "keychain_present": prefix + "Keychain.plist" in mapping,
        "data": {"files": 0, "directories": 0, "empty_files": 0,
                 "methods": {}, "unix_permission_entry_count": 0},
    }
    metadata_name = prefix + "Metadata.plist"
    if metadata_name in mapping:
        attrs, metadata_format = _read_plist_and_format(zf,
                                                         mapping[metadata_name])
        observed = set()
        unknown_attrs = 0
        for row in attrs.values():
            if not isinstance(row, dict):
                raise ComparisonUnavailable("malformed metadata attributes")
            for key in row:
                if key in KNOWN_METADATA_KEYS:
                    observed.add(key)
                else:
                    unknown_attrs += 1
        signature["metadata"] = {
            "present": True,
            "format": metadata_format,
            "entry_count": len(attrs),
            "known_attribute_fields": sorted(observed),
            "unrecognized_attribute_field_count": unknown_attrs,
        }
    data = signature["data"]
    methods: Counter[str] = Counter()
    for name, member in mapping.items():
        if not name.startswith(prefix):
            continue
        relative = name[len(prefix):]
        if relative in ("Info.plist", "Metadata.plist", "Keychain.plist"):
            continue
        if member.is_dir():
            data["directories"] += 1
        else:
            data["files"] += 1
            if member.file_size == 0:
                data["empty_files"] += 1
        if member.create_system == 3 and (member.external_attr >> 16) & 0o777:
            data["unix_permission_entry_count"] += 1
        methods[str(member.compress_type)] += 1
    data["methods"] = dict(sorted(methods.items()))
    return signature


def archive_profile(path: str | os.PathLike[str], *,
                    verify_payload: bool = False) -> dict[str, Any]:
    # Insist on the independently validated ZIP shape first. This also rejects
    # traversal, symlinks, duplicate/unsafe members and encrypted archives.
    result = inspect_archive(path, verify_payload=verify_payload)
    records = result["containers"]
    if len(records) > MAX_CONTAINERS:
        raise ComparisonUnavailable("too many containers for comparison")
    with zipfile.ZipFile(path, "r") as zf:
        mapping = {name.rstrip("/"): member
                   for name, member in ((entry.filename, entry)
                                        for entry in zf.infolist())}
        containers = []
        if result["kind"] == "single":
            containers.append(_container_signature(zf, mapping, ""))
            root_index = {"present": False, "format": None,
                          "known_fields": [], "unrecognized_field_count": 0}
        else:
            for record in records:
                prefix = (record["application_identifier"] + "/" +
                          record["container_identifier"] + "/")
                containers.append(_container_signature(zf, mapping, prefix))
            index, index_format = _read_plist_and_format(zf,
                                                         mapping["Info.plist"])
            root_index = {
                "present": True, "format": index_format,
                "known_fields": (["containedContainers"]
                                 if "containedContainers" in index else []),
                "unrecognized_field_count":
                    sum(key != "containedContainers" for key in index),
            }
        # Sorting hides source/order identity and makes multi comparisons
        # independent of container ordering in the two archives.
        containers.sort(key=lambda row: json.dumps(row, sort_keys=True))
        return {
            "kind": result["kind"],
            "container_count": len(containers),
            "root_index": root_index,
            "containers": containers,
            "member_count": result["member_count"],
            "non_keychain_crc_verified":
                result["non_keychain_payload_crc_verified"],
            "keychain_contents_read": False,
            "extracted": False,
        }


def _compare_values(reference: Any, candidate: Any,
                    path: str, differences: list[dict[str, Any]]) -> None:
    if isinstance(reference, dict) and isinstance(candidate, dict):
        # Keys here are fixed, authored signature names or method integers,
        # never names copied from untrusted archive data.
        for key in sorted(set(reference) | set(candidate)):
            _compare_values(reference.get(key), candidate.get(key),
                            path + "." + key, differences)
    elif isinstance(reference, list) and isinstance(candidate, list):
        if len(reference) != len(candidate):
            differences.append({"field": path + ".length",
                                "reference": len(reference),
                                "candidate": len(candidate)})
        for index, (a, b) in enumerate(zip(reference, candidate)):
            _compare_values(a, b, f"{path}.{index}", differences)
    elif reference != candidate:
        differences.append({
            "field": path,
            "reference": reference,
            "candidate": candidate,
        })


def compare_archives(reference: str | os.PathLike[str],
                     candidate: str | os.PathLike[str],
                     *, verify_payload: bool = False) -> dict[str, Any]:
    # Same archive cannot establish parity between two implementations.
    if Path(reference).resolve(strict=True) == Path(candidate).resolve(strict=True):
        raise ComparisonUnavailable("reference and candidate are the same file")
    first = archive_profile(reference, verify_payload=verify_payload)
    second = archive_profile(candidate, verify_payload=verify_payload)
    differences: list[dict[str, Any]] = []
    keys = ("kind", "container_count", "root_index", "containers",
            "member_count")
    for key in keys:
        _compare_values(first[key], second[key], key, differences)
    return {
        "status": ("structural_shape_match_not_proven"
                   if not differences else "structural_differences_found"),
        "original_compatibility_proven": False,
        "restore_safe": False,
        "non_keychain_crc_verified": (first["non_keychain_crc_verified"]
                                       and second["non_keychain_crc_verified"]),
        "keychain_contents_read": False,
        "extracted": False,
        "differences": differences,
        "difference_count": len(differences),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Compare Crane backup structure, NOT contents/authenticity. "
        "Output excludes container IDs, member names, paths and Keychain data."))
    parser.add_argument("--reference", required=True,
                        help="prefer disposable-app original .cranect/.cranebk")
    parser.add_argument("--candidate", required=True,
                        help="offline fixture-writer output to compare")
    parser.add_argument("--verify-payload", action="store_true",
                        help="inspect non-Keychain CRCs (bounded, read-only)")
    args = parser.parse_args(argv)
    try:
        result = compare_archives(args.reference, args.candidate,
                                  verify_payload=args.verify_payload)
        status = 0 if result["difference_count"] == 0 else 1
    except UnsupportedArchive:
        result, status = ({"status": "unsupported_not_validated",
                           "original_compatibility_proven": False}, 2)
    except (ComparisonUnavailable, InvalidArchive, OSError, ValueError,
            TypeError, OverflowError, RecursionError, zipfile.BadZipFile):
        # Never echo raw exception text: inspector's error descriptions can
        # include untrusted ZIP entry names; CLI must not leak private paths.
        result, status = ({"status": "unavailable_or_invalid",
                           "original_compatibility_proven": False}, 2)
    print(json.dumps(result, sort_keys=True, ensure_ascii=True))
    return status


if __name__ == "__main__":
    sys.exit(main())
