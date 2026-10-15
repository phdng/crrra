#!/usr/bin/env python3
"""G-11 offline restore preflight: compare archive records to explicit test inventory.

READ-ONLY, advisory only. No extraction, no target filesystem access, no
container manager/helper, no rollback or restore execution. Results are redacted:
no app/container/group IDs or paths; a 'pass' never authorizes restore.

Original: 0x29A84 multi mapping selection, 0x29CAC single application-ID
check, 0x2A298/0x2A7CC DEFAULT group check, 0x2ADA0 wipe-before-move.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import sys
from typing import Any
import zipfile

from crane_backup_inspector import (
    InvalidArchive, UnsupportedArchive, _safe_id, _read_small_plist,
    inspect_archive,
)

MAX_INVENTORY_BYTES = 256 * 1024
MAX_MAPPINGS = 50
MAX_ASSOCIATED_IDS = 256

class PreflightError(Exception):
    """Invalid inventory, mapping or unsupported preflight request."""


def _valid_id(value: Any) -> str:
    try:
        return _safe_id(value, "identifier")
    except InvalidArchive as exc:
        raise PreflightError("invalid identifier") from exc


def _id_list(value: Any) -> frozenset[str]:
    if not isinstance(value, list) or not (1 <= len(value) <= MAX_ASSOCIATED_IDS):
        raise PreflightError("invalid associated-identifier list")
    identifiers = [_valid_id(item) for item in value]
    if len({item.casefold() for item in identifiers}) != len(identifiers):
        raise PreflightError("duplicate associated identifier")
    return frozenset(identifiers)


def _inventory(path: str | Path) -> tuple[list[dict[str, Any]], int | None]:
    f = Path(path)
    if f.is_symlink() or not f.is_file():
        raise PreflightError("inventory is not a regular file")
    if f.stat().st_size > MAX_INVENTORY_BYTES:
        raise PreflightError("inventory exceeds size limit")
    try:
        data = json.loads(f.read_bytes().decode("utf-8"))
    except (ValueError, UnicodeError, OSError) as exc:
        raise PreflightError("invalid JSON inventory") from exc
    if not isinstance(data, dict) or set(data) != {"targets", "mappings", "freeBytes"}:
        raise PreflightError("inventory requires targets, mappings and freeBytes")
    targets, mappings = data["targets"], data["mappings"]
    capacity = data["freeBytes"]
    if capacity is not None and (
        isinstance(capacity, bool) or not isinstance(capacity, int)
        or capacity < 0 or capacity > 2**63 - 1
    ):
        raise PreflightError("invalid freeBytes")
    if not isinstance(targets, list) or not 1 <= len(targets) <= MAX_MAPPINGS:
        raise PreflightError("invalid targets")
    if not isinstance(mappings, list) or not 1 <= len(mappings) <= MAX_MAPPINGS:
        raise PreflightError("invalid mappings")
    parsed_targets: dict[tuple[str, str], dict[str, Any]] = {}
    for item in targets:
        if not isinstance(item, dict) or set(item) != {
            "applicationIdentifier", "containerIdentifier",
            "defaultAssociatedIdentifiers", "targetAssociatedIdentifiers",
            "active", "existingData",
        }:
            raise PreflightError("invalid target schema")
        app = _valid_id(item["applicationIdentifier"])
        cid = _valid_id(item["containerIdentifier"])
        key = (app, cid)
        if key in parsed_targets:
            raise PreflightError("duplicate target")
        if type(item["active"]) is not bool or type(item["existingData"]) is not bool:
            raise PreflightError("invalid active/existingData state")
        current = _id_list(item["defaultAssociatedIdentifiers"])
        selected = _id_list(item["targetAssociatedIdentifiers"])
        if not selected.issubset(current):
            raise PreflightError("target identifiers not in app DEFAULT inventory")
        parsed_targets[key] = {
            "default": current,
            "selected": selected,
            "active": item["active"],
            "existing_data": item["existingData"],
        }
    selected_source: set[tuple[str, str]] = set()
    selected_target: set[tuple[str, str]] = set()
    result = []
    for item in mappings:
        if not isinstance(item, dict) or set(item) != {
            "sourceApplicationIdentifier", "sourceContainerIdentifier",
            "targetApplicationIdentifier", "targetContainerIdentifier",
        }:
            raise PreflightError("invalid mapping schema")
        source = (_valid_id(item["sourceApplicationIdentifier"]),
                  _valid_id(item["sourceContainerIdentifier"]))
        target = (_valid_id(item["targetApplicationIdentifier"]),
                  _valid_id(item["targetContainerIdentifier"]))
        if source in selected_source or target in selected_target:
            raise PreflightError("reused source or target mapping")
        if target not in parsed_targets:
            raise PreflightError("mapping has no corresponding target inventory")
        selected_source.add(source)
        selected_target.add(target)
        result.append({"source": source, "target": target,
                       **parsed_targets[target]})
    return result, capacity


def _source_info(zf: zipfile.ZipFile, kind: str,
                 source: tuple[str, str]) -> dict[str, Any]:
    prefix = (source[0] + "/" + source[1] + "/") if kind == "multi" else ""
    member = prefix + "Info.plist"
    try:
        info = zf.getinfo(member)
    except KeyError as exc:
        raise PreflightError("source metadata missing") from exc
    return _read_small_plist(zf, info)


def _original_identifiers(info: dict[str, Any], app: str) -> frozenset[str]:
    paths = info.get("originalPaths")
    if paths is None:
        paths = info.get("applicationGroups")
        if not isinstance(paths, dict) or "originalPath" not in info:
            raise PreflightError("source missing original path metadata")
        paths = dict(paths)
        paths[app] = info["originalPath"]
    if not isinstance(paths, dict) or not paths:
        raise PreflightError("invalid source path metadata")
    ids = [_valid_id(name) for name in paths]
    if len({value.casefold() for value in ids}) != len(ids):
        raise PreflightError("duplicate source associated IDs")
    return frozenset(ids)


def preflight(archive_path: str | Path, inventory_path: str | Path) -> dict[str, Any]:
    archive = Path(archive_path)
    verified = inspect_archive(archive, verify_payload=False)
    chosen, available = _inventory(inventory_path)
    # The native 0x28FE0 free-space estimate is approximately 1.2x archive
    # size. This is only an advisory lower-bound estimate, NOT an allocation
    # or transactional reserve.
    required = (archive.stat().st_size * 6 + 4) // 5
    source_rows = {(row["application_identifier"],
                    row["container_identifier"]): row
                   for row in verified["containers"]}
    if verified["kind"] == "single" and len(chosen) != 1:
        raise PreflightError("single archive needs exactly one target")
    if verified["kind"] == "multi" and len(chosen) > len(source_rows):
        raise PreflightError("more mappings than source containers")

    mapped = []
    all_reasons: set[str] = set()
    if available is None:
        all_reasons.add("free_space_unknown")
    elif available < required:
        all_reasons.add("insufficient_estimated_free_space")
    with zipfile.ZipFile(archive, "r") as zf:
        for mapping in chosen:
            source, target = mapping["source"], mapping["target"]
            if source not in source_rows:
                raise PreflightError("mapping selects absent backup container")
            info = _source_info(zf, verified["kind"], source)
            original_ids = _original_identifiers(info, source[0])
            reasons = set()
            if source[0] != target[0]:
                reasons.add("application_identifier_mismatch")
            # Original 0x2A7CC checks each original associated ID against
            # DEFAULT app inventory (extra current IDs are fine).
            missing = original_ids - mapping["default"]
            if missing:
                reasons.add("associated_identifier_confirmation_required")
            # The selected target can differ from DEFAULT (e.g. app removed).
            if original_ids - mapping["selected"]:
                reasons.add("target_associated_identifier_unavailable")
            if mapping["active"]:
                reasons.add("target_active_reload_unverified")
            if mapping["existing_data"]:
                reasons.add("overwrite_requires_snapshot_and_rollback")
            if source_rows[source]["has_keychain"]:
                reasons.add("keychain_restore_backend_unavailable")
            all_reasons.update(reasons)
            mapped.append({
                "index": len(mapped) + 1,
                "reason_codes": sorted(reasons),
                "group_confirmation_required":
                    "associated_identifier_confirmation_required" in reasons,
                "keychain_present": source_rows[source]["has_keychain"],
            })
    # A clean advisory result does not permit restore. The real native
    # implementation still needs staging, callbacks, snapshot & rollback.
    return {
        "status": "preflight_blocked" if all_reasons else "preflight_advisory_only",
        "restore_executable": False,
        "original_compatibility_proven": False,
        "inventory_verified_against_device": False,
        "free_space_verified_on_device": False,
        "payload_crc_verified": False,
        "rollback_implemented": False,
        "wrote_files": False,
        "extracted": False,
        "keychain_contents_read": False,
        "archive_kind": verified["kind"],
        "archive_container_count": len(source_rows),
        "mapping_count": len(mapped),
        "estimated_required_bytes": required,
        "available_bytes_supplied": available is not None,
        "reason_codes": sorted(all_reasons),
        "mappings": mapped,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Read-only OFFLINE Crane restore mapping preflight; never performs restore"))
    parser.add_argument("--archive", required=True)
    parser.add_argument("--inventory", required=True,
                        help="explicit JSON test target inventory; no device access")
    args = parser.parse_args(argv)
    try:
        report = preflight(args.archive, args.inventory)
        status = 1 if report["reason_codes"] else 0
    except (PreflightError, InvalidArchive, OSError, ValueError, TypeError,
            KeyError, zipfile.BadZipFile, UnsupportedArchive):
        # Never print exception details: archives or JSON may contain IDs or
        # paths. The CLI intentionally emits only a fixed status string.
        report = {"status": "preflight_unavailable_or_invalid",
                  "restore_executable": False}
        status = 2
    print(json.dumps(report, sort_keys=True))
    return status


if __name__ == "__main__":
    sys.exit(main())
