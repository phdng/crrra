#!/usr/bin/env python3
"""G-11 forensic audit of a user-provided original Crane ZIP, READ-ONLY.

No payload/Keychain data is read by default; optional non-Keychain CRC streams
within inspector's bound. Never emits ZIP member names, app/container IDs,
file paths, plist field values, unknown plist field names or raw errors.
This does not prove compatibility or authorize backup/restore.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import stat
import sys
import zipfile

from crane_backup_inspector import (
    InvalidArchive, UnsupportedArchive,
    _read_small_plist, inspect_archive,
)
from crane_backup_shape_compare import (
    ComparisonUnavailable, archive_profile,
)
from crane_backup_metadata import WRITABLE_FILE_ATTRIBUTES

MAX_ARCHIVE_ENTRIES = 100_000


class AuditUnavailable(Exception):
    """ZIP isn't safely inspectable in this audit."""


def audit_original(path: str | Path, *, verify_payload: bool = False) -> dict:
    source = Path(path)
    if source.is_symlink() or not source.is_file():
        raise AuditUnavailable("file must be regular, not a symlink")
    before = source.stat()
    if not stat.S_ISREG(before.st_mode):
        raise AuditUnavailable("file must be regular")
    with zipfile.ZipFile(source, mode="r") as zf:
        entries = zf.infolist()
        if len(entries) > MAX_ARCHIVE_ENTRIES:
            raise AuditUnavailable("too many members")
        compression = Counter(str(item.compress_type) for item in entries)
        encrypted = sum(bool(item.flag_bits & 0x01) for item in entries)
        keychain_count = sum(
            item.filename == "Keychain.plist"
            or item.filename.endswith("/Keychain.plist")
            for item in entries
        )
        directory_count = sum(item.is_dir() for item in entries)
        unix_permissions = Counter()
        for item in entries:
            if item.create_system == 3:
                kind = stat.S_IFMT(item.external_attr >> 16)
                unix_permissions["unix_directory" if item.is_dir()
                                 else "unix_regular"] += 1
                if kind == stat.S_IFLNK:
                    unix_permissions["unix_symlink"] += 1
        zip_details = {
            "members": len(entries),
            "file_members": len(entries) - directory_count,
            "directories": directory_count,
            "empty_files": sum(not item.is_dir() and not item.file_size
                               for item in entries),
            "uncompressed_bytes_claimed": sum(item.file_size for item in entries),
            "compressed_member_methods": dict(sorted(compression.items())),
            "encrypted_members": encrypted,
            "keychain_member_count": keychain_count,
            "unix_flags": dict(sorted(unix_permissions.items())),
        }
    result = {
        "status": "original_structure_not_yet_validated",
        "archive_role": "user_supplied_original_claim_not_authenticity_proof",
        "zip": zip_details,
        "inspector_status": "not_run",
        "inspector_kind": None,
        "containers": [],
        "writable_metadata_allowlist": sorted(WRITABLE_FILE_ATTRIBUTES),
        "crc_non_keychain_verified": False,
        "original_compatibility_proven": False,
        "keychain_contents_read": False,
        "payload_extracted": False,
        "filesystem_writes": False,
        "restore_safe": False,
    }
    try:
        inspected = inspect_archive(source, verify_payload=verify_payload)
        profile = archive_profile(source, verify_payload=False)
    except UnsupportedArchive:
        result["status"] = "original_format_unsupported"
        result["inspector_status"] = "unsupported"
        return result
    except (InvalidArchive, ComparisonUnavailable, ValueError, TypeError):
        result["status"] = "original_format_inspector_rejected"
        result["inspector_status"] = "invalid"
        return result
    result["status"] = "original_structure_accepted_not_parity_proof"
    result["inspector_status"] = "accepted"
    result["inspector_kind"] = inspected["kind"]
    result["crc_non_keychain_verified"] = inspected[
        "non_keychain_payload_crc_verified"]
    result["profile_root"] = profile["root_index"]
    result["containers"] = profile["containers"]
    result["container_count"] = profile["container_count"]
    # Evidence from Metadata.plist only; no app payload or Keychain.
    # Report fixed known field names and Python value TYPE COUNTS,
    # never UID/GID/name/mtime values, associated IDs or source paths.
    observations = []
    with zipfile.ZipFile(source, "r") as zf:
        for item in inspected["containers"]:
            prefix = (f"{item['application_identifier']}/"
                      f"{item['container_identifier']}/"
                      if inspected["kind"] == "multi" else "")
            metadata_member = prefix + "Metadata.plist"
            if not item["has_metadata"]:
                observations.append({"metadata_present": False})
                continue
            attrs = _read_small_plist(zf, zf.getinfo(metadata_member))
            payload_names = {
                member.filename[len(prefix):].rstrip("/")
                for member in zf.infolist()
                if member.filename.startswith(prefix)
                and member.filename[len(prefix):].rstrip("/")
                not in {"Info.plist", "Metadata.plist", "Keychain.plist"}
            }
            signature_counts = Counter()
            type_counts = {key: Counter() for key in WRITABLE_FILE_ATTRIBUTES}
            key_presence = Counter()
            orphaned = 0
            for rel, attributes in attrs.items():
                if rel.rstrip("/") not in payload_names:
                    orphaned += 1
                keys = tuple(sorted(
                    name for name in attributes if name in WRITABLE_FILE_ATTRIBUTES
                ))
                signature_counts["+".join(keys)] += 1
                for key in keys:
                    key_presence[key] += 1
                    value = attributes[key]
                    kind = (
                        "datetime" if isinstance(value, datetime)
                        else "bool" if isinstance(value, bool)
                        else "integer" if type(value) is int
                        else "string" if isinstance(value, str)
                        else "other"
                    )
                    type_counts[key][kind] += 1
            observations.append({
                "metadata_present": True,
                "records": len(attrs),
                "zip_data_members": len(payload_names),
                "orphaned_metadata_records": orphaned,
                "zip_data_without_metadata": len(payload_names - set(attrs)),
                "attribute_presence_counts": dict(sorted(key_presence.items())),
                "attribute_value_types": {
                    key: dict(sorted(value.items()))
                    for key, value in sorted(type_counts.items()) if value
                },
                "attribute_set_variants": len(signature_counts),
            })
    result["metadata_observations"] = observations
    # Best-effort guard against a ZIP replaced or altered during audit.
    after = source.stat()
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, name) != getattr(after, name) for name in fields):
        raise AuditUnavailable("source file changed during audit")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Original Crane ZIP format audit: redacted and read-only, never restore"))
    parser.add_argument("--archive", required=True)
    parser.add_argument("--verify-payload", action="store_true",
                        help="bounded CRC scan (except Keychain) via inspector")
    args = parser.parse_args(argv)
    try:
        result = audit_original(args.archive,
                                verify_payload=args.verify_payload)
        code = 0 if result["inspector_status"] == "accepted" else 2
    except (AuditUnavailable, InvalidArchive, OSError, RuntimeError,
            zipfile.BadZipFile, KeyError, ValueError, TypeError,
            OverflowError, RecursionError, EOFError):
        result = {
            "status": "original_archive_unavailable_or_invalid",
            "original_compatibility_proven": False,
            "keychain_contents_read": False,
            "filesystem_writes": False,
            "restore_safe": False,
        }
        code = 2
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
