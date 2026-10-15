#!/usr/bin/env python3
"""G-11 D3: read-only, redacted restore WORK MANIFEST for Crane-shaped ZIPs.

This is a planning/inspection report, NOT a restore implementation.
It joins D0's explicit test inventory with the ZIP central directory and
bounded per-container Info.plist/Metadata.plist records. It NEVER extracts,
writes, reads Keychain or app payload, resolves iPhone paths, or invokes
CraneManager. An optional CRC pass streams non-Keychain payloads via the
existing bounded inspector.

The original file format has not been proven with a genuine disposable-app
Crane archive. A clean report NEVER grants permission to execute a restore.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import sys
from typing import Any
import zipfile

from crane_backup_inspector import (
    InvalidArchive, UnsupportedArchive, _read_small_plist, inspect_archive,
)
from crane_backup_metadata import WRITABLE_FILE_ATTRIBUTES
from crane_restore_preflight import (
    PreflightError, _inventory, _original_identifiers, preflight,
)

MAX_PLAN_MAPPINGS = 50
MAX_METADATA_RECORDS = 100_000


class PlanError(Exception):
    """Invalid metadata or unsupported plan invariant."""


def _file_identity(path: Path) -> tuple[int, int, int, int]:
    """Best-effort guard against input replacement during repeated scans."""
    if path.is_symlink():
        raise PlanError("input is symlink")
    stat = path.stat()
    if not path.is_file():
        raise PlanError("input is not a file")
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns


def _classify_metadata(attrs: Any) -> set[str]:
    """Check only values safe to classify; NEVER apply attributes to files."""
    errors: set[str] = set()
    if not isinstance(attrs, dict):
        return {"metadata_invalid_attributes"}
    for key, value in attrs.items():
        if key not in WRITABLE_FILE_ATTRIBUTES:
            errors.add("metadata_unknown_attributes")
            continue
        if key in ("NSFilePosixPermissions", "NSFileOwnerAccountID",
                   "NSFileGroupOwnerAccountID"):
            if type(value) is not int or value < 0:
                errors.add("metadata_invalid_attributes")
            elif key == "NSFilePosixPermissions" and value > 0o7777:
                errors.add("metadata_invalid_attributes")
            elif key == "NSFilePosixPermissions" and value & 0o6002:
                # setuid/setgid + world-writable: manual review before
                # any future restore; do not attempt a chmod.
                errors.add("metadata_privileged_or_world_writable")
        elif key in ("NSFileCreationDate", "NSFileModificationDate"):
            if not isinstance(value, datetime):
                errors.add("metadata_invalid_attributes")
        elif key in ("NSFileBusy", "NSFileExtensionHidden", "NSFileImmutable"):
            if type(value) is not bool:
                errors.add("metadata_invalid_attributes")
        elif key in ("NSFileOwnerAccountName", "NSFileGroupOwnerAccountName"):
            if type(value) is not str or len(value) > 256:
                errors.add("metadata_invalid_attributes")
        elif key in ("NSFileHFSCreatorCode", "NSFileHFSTypeCode"):
            if type(value) is not int or not 0 <= value <= 0xFFFFFFFF:
                errors.add("metadata_invalid_attributes")
    return errors


def plan_restore(archive: str | Path, inventory: str | Path,
                 *, verify_payload: bool = False) -> dict[str, Any]:
    path = Path(archive)
    inventory_path = Path(inventory)
    archive_identity = _file_identity(path)
    inventory_identity = _file_identity(inventory_path)
    original_check = inspect_archive(path, verify_payload=verify_payload)
    checked = preflight(path, inventory_path)
    selected, _capacity = _inventory(inventory_path)

    if len(selected) != checked["mapping_count"]:
        raise PlanError("preflight mapping count changed")
    if len(selected) > MAX_PLAN_MAPPINGS:
        raise PlanError("too many mappings")

    sources = {
        (entry["application_identifier"], entry["container_identifier"]): entry
        for entry in original_check["containers"]
    }
    overall_reasons: set[str] = set(checked["reason_codes"])
    unmapped = len(sources) - len(selected)
    results: list[dict[str, Any]] = []

    with zipfile.ZipFile(path, mode="r") as zf:
        names = {name.rstrip("/"): member for member in zf.infolist()
                 for name in [member.filename]}
        # A second view of the ZIP is still bounded by inspect_archive.
        for index, target in enumerate(selected, 1):
            source_id = target["source"]
            if source_id not in sources:
                raise PlanError("source absent")
            prefix = (source_id[0] + "/" + source_id[1] + "/") if (
                original_check["kind"] == "multi") else ""
            info_name = prefix + "Info.plist"
            info = _read_small_plist(zf, names[info_name])
            associated_ids = _original_identifiers(info, source_id[0])
            reasons = set(checked["mappings"][index - 1]["reason_codes"])

            per_source = {name[len(prefix):]: member
                          for name, member in names.items()
                          if name.startswith(prefix)}
            # The independent inspector checked member prefixes, IDs and
            # traversal/symlink/duplicate paths. This planner never joins
            # original path strings against the host filesystem.
            payloads = {
                relative: member
                for relative, member in per_source.items()
                if relative not in (
                    "Info.plist", "Metadata.plist", "Keychain.plist"
                )
            }
            explicit_dirs = sum(member.is_dir() for member in payloads.values())
            files = sum(not member.is_dir() for member in payloads.values())
            empty_files = sum(
                not member.is_dir() and member.file_size == 0
                for member in payloads.values()
            )
            total_size = sum(
                member.file_size for member in payloads.values()
                if not member.is_dir()
            )
            present_associated_ids = {
                relative.split("/")[0] for relative in payloads
            }
            missing_associated_ids = associated_ids - present_associated_ids
            if missing_associated_ids:
                reasons.add("associated_data_absent_from_archive")
            orphaned_metadata = 0
            unknown_attribute_records = 0
            reviewed_metadata_records = 0
            metadata_name = "Metadata.plist"
            if metadata_name in per_source:
                values = _read_small_plist(zf, per_source[metadata_name])
                if len(values) > MAX_METADATA_RECORDS:
                    raise PlanError("metadata too many records")
                for relative, attrs in values.items():
                    if not isinstance(relative, str):
                        raise PlanError("invalid metadata key")
                    reviewed_metadata_records += 1
                    if relative.rstrip("/") not in payloads:
                        orphaned_metadata += 1
                    attr_reasons = _classify_metadata(attrs)
                    if "metadata_unknown_attributes" in attr_reasons:
                        unknown_attribute_records += 1
                    reasons.update(attr_reasons)
                if orphaned_metadata:
                    reasons.add("metadata_paths_without_zip_entries")

            # Do not read the contents or CRC of Keychain.plist.
            if sources[source_id]["has_keychain"]:
                reasons.add("keychain_restore_backend_unavailable")

            overall_reasons.update(reasons)
            results.append({
                "index": index,
                "associated_identifier_count": len(associated_ids),
                "associated_identifiers_without_payload":
                    len(missing_associated_ids),
                "files": files,
                "empty_files": empty_files,
                "explicit_directories": explicit_dirs,
                "claimed_payload_bytes": total_size,
                "metadata_records": reviewed_metadata_records,
                "metadata_orphan_records": orphaned_metadata,
                "metadata_unknown_attribute_records":
                    unknown_attribute_records,
                "keychain_present": sources[source_id]["has_keychain"],
                "reason_codes": sorted(reasons),
            })

    # Conservative TOCTOU guard: file replacement/size/time change during
    # the independent inspector/preflight/scans invalidates this report.
    # This does NOT prove immutable inputs against adversarial writers.
    if (_file_identity(path) != archive_identity or
            _file_identity(inventory_path) != inventory_identity):
        raise PlanError("inputs changed during read-only plan")

    # This is deliberately not a target path mapping or a command list.
    # Even a structurally clean archive has neither device confirmation nor
    # transaction snapshot, recovery, original compatibility or Keychain.
    return {
        "status": ("work_plan_blocked_or_review_required"
                   if overall_reasons else "work_plan_advisory_only"),
        "restore_executable": False,
        "original_compatibility_proven": False,
        "device_target_paths_verified": False,
        "rollback_implemented": False,
        "wrote_files": False,
        "extracted": False,
        "keychain_contents_read": False,
        "non_keychain_crc_verified":
            original_check["non_keychain_payload_crc_verified"],
        "archive_kind": original_check["kind"],
        "mapped_containers": len(results),
        "unmapped_archive_containers": unmapped,
        "selected_payload_files": sum(x["files"] for x in results),
        "selected_payload_bytes_claimed":
            sum(x["claimed_payload_bytes"] for x in results),
        "reason_codes": sorted(overall_reasons),
        "containers": results,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Redacted, read-only Crane ZIP restore work manifest; "
        "NO extraction, writes or on-device restore"))
    parser.add_argument("--archive", required=True)
    parser.add_argument("--inventory", required=True,
                        help="offline test JSON inventory (not a live device view)")
    parser.add_argument("--verify-payload", action="store_true",
                        help="bounded non-Keychain CRC check, no extraction")
    args = parser.parse_args(argv)
    try:
        result = plan_restore(args.archive, args.inventory,
                              verify_payload=args.verify_payload)
        exit_code = 0 if not result["reason_codes"] else 1
    except (PlanError, PreflightError, InvalidArchive, UnsupportedArchive,
            OSError, ValueError, TypeError, KeyError, RuntimeError,
            zipfile.BadZipFile):
        # Internal exception messages may include names and originalPaths.
        result = {"status": "work_plan_invalid_or_unavailable",
                  "restore_executable": False}
        exit_code = 2
    print(json.dumps(result, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
