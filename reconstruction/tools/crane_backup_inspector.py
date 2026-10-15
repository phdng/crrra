#!/usr/bin/env python3
"""Read-only structural inspector for original Crane .cranect/.cranebk backups.

G-11 read-only inspection only: NO extract(), extractall(), ZIP creation,
restore, or calls to CraneManager/helperd. By default only small Info.plist/
Metadata.plist records are read. With --verify-payload, non-Keychain data
is streamed (never stored/printed) under a 256 MiB budget for ZIP CRC checks.
Keychain.plist contents are NEVER opened/read or printed.

The original binary is the source of the schema, but without real original
fixtures passing this inspector is NOT proof of backup compatibility.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
import zlib
import zipfile
from typing import Any

MAX_MEMBERS = 100_000
MAX_MEMBER_SIZE = 4 * 1024 ** 3
MAX_TOTAL_SIZE = 16 * 1024 ** 3
MAX_COMPRESSION_RATIO = 1_000
MAX_PLIST_BYTES = 2 * 1024 ** 2
MAX_NAME_LENGTH = 1024
MAX_DEPTH = 32
# Optional deeper consistency check; it reads (never extracts) non-Keychain
# file contents in chunks and lets zipfile verify their CRC at EOF.
MAX_VERIFY_BYTES = 256 * 1024 ** 2
VERIFY_CHUNK_BYTES = 1024 ** 2

class InvalidArchive(Exception):
    """Archive violates a structural or schema invariant."""

class UnsupportedArchive(Exception):
    """Cannot inspect fully and safely (e.g. encrypted or oversized)."""


def _require(condition: bool, why: str) -> None:
    if not condition:
        raise InvalidArchive(why)


def _safe_member_name(raw: str) -> str:
    _require(isinstance(raw, str) and len(raw) <= MAX_NAME_LENGTH and bool(raw),
             "empty or overlong ZIP entry name")
    _require(not raw.startswith(("/", "\\")) and "\\" not in raw,
             "absolute or backslash ZIP entry path")
    _require(not re.match(r"^[A-Za-z]:", raw), "drive-qualified ZIP entry")
    _require(all(32 <= ord(c) != 127 for c in raw),
             "control character in ZIP entry name")
    trimmed = raw[:-1] if raw.endswith("/") else raw
    components = trimmed.split("/")
    _require(len(components) <= MAX_DEPTH and
             all(part and part not in (".", "..") for part in components),
             "ZIP entry contains empty/dot/traversal path component")
    return trimmed


def _safe_id(value: Any, label: str) -> str:
    _require(isinstance(value, str) and 0 < len(value) <= 255,
             f"missing/invalid {label}")
    _require(value not in (".", "..") and
             not any(c in value for c in ("/", "\\", "\x00", ":")) and
             all(ord(c) >= 32 and ord(c) != 127 for c in value),
             f"unsafe {label}")
    return value


def _safe_original_path(value: Any) -> None:
    # An originalPath is metadata, NEVER a location to open on this computer.
    _require(isinstance(value, str) and value.startswith("/") and
             len(value) <= 4096 and "\\" not in value and
             all(ord(c) >= 32 and ord(c) != 127 for c in value) and
             ".." not in value.split("/"),
             "unsafe originalPaths metadata value")


def _paths_in_info(info: dict[str, Any]) -> set[str]:
    paths = info.get("originalPaths")
    if paths is None:
        # Native restore 0x2A298/0x2B31C supports legacy schema.
        legacy_groups = info.get("applicationGroups")
        legacy_app_path = info.get("originalPath")
        _require(isinstance(legacy_groups, dict) and bool(legacy_app_path),
                 "Info.plist has neither originalPaths nor legacy paths")
        paths = dict(legacy_groups)
        app_id = info.get("applicationIdentifier")
        paths[_safe_id(app_id, "applicationIdentifier")] = legacy_app_path
    _require(isinstance(paths, dict) and bool(paths),
             "Info.plist originalPaths must be a nonempty dictionary")
    result: set[str] = set()
    folded: set[str] = set()
    for key, value in paths.items():
        name = _safe_id(key, "associated path identifier")
        _safe_original_path(value)
        _require(name.casefold() not in folded,
                 "duplicate associated path identifier")
        folded.add(name.casefold())
        result.add(name)
    return result


def _read_small_plist(zf: zipfile.ZipFile, item: zipfile.ZipInfo) -> dict:
    _require(item.file_size <= MAX_PLIST_BYTES,
             f"oversized plist: {item.filename}")
    try:
        with zf.open(item, "r") as handle:
            data = handle.read(MAX_PLIST_BYTES + 1)
    except (RuntimeError, OSError, EOFError, zipfile.BadZipFile, zlib.error) as exc:
        raise InvalidArchive(f"unreadable plist: {item.filename}") from exc
    _require(len(data) <= MAX_PLIST_BYTES, "plist exceeded byte limit")
    try:
        parsed = plistlib.loads(data)
    except (ValueError, TypeError, OSError, OverflowError, RecursionError) as exc:
        raise InvalidArchive(f"invalid property list: {item.filename}") from exc
    _require(isinstance(parsed, dict), f"plist is not a dictionary: {item.filename}")
    return parsed


def _validate_info(info: dict, expected_app: str | None = None,
                   expected_container: str | None = None) -> tuple[str, str, set[str]]:
    app = _safe_id(info.get("applicationIdentifier"), "applicationIdentifier")
    container = _safe_id(info.get("containerIdentifier"), "containerIdentifier")
    if expected_app is not None:
        _require(app == expected_app, "container Info.plist application ID mismatch")
    if expected_container is not None:
        _require(container == expected_container, "container Info.plist container ID mismatch")
    name = info.get("containerName")
    _require(name is None or (isinstance(name, str) and len(name) <= 1024),
             "invalid containerName")
    vendor = info.get("deviceIdentifierForVendor")
    _require(vendor is None or (isinstance(vendor, str) and len(vendor) <= 128),
             "invalid deviceIdentifierForVendor")
    return app, container, _paths_in_info(info)


def _check_payload(zf: zipfile.ZipFile,
                   names: dict[str, zipfile.ZipInfo], prefix: str,
                   ids: set[str]) -> dict[str, bool | int]:
    local_names = [name[len(prefix):] for name in names if name.startswith(prefix)]
    _require("Info.plist" in local_names, f"missing {prefix}Info.plist")
    seen_data = 0
    for name in local_names:
        if name in ("Info.plist", "Keychain.plist", "Metadata.plist"):
            _require(not names[prefix + name].is_dir(),
                     f"special member is directory: {prefix + name}")
            continue
        parts = name.split("/")
        _require(parts[0] in ids, f"unrecognized associated path: {prefix + name}")
        # An explicit top directory member can be named '<associatedID>/'.
        if len(parts) == 1:
            _require(names[prefix + name].is_dir(),
                     f"unexpected data file at associated-root: {prefix + name}")
        seen_data += 1
    if "Metadata.plist" in local_names:
        metadata = _read_small_plist(zf, names[prefix + "Metadata.plist"])
        for relative, attrs in metadata.items():
            normalized = _safe_member_name(relative)
            _require(not relative.endswith("/") and
                     normalized.split("/")[0] in ids,
                     "Metadata.plist attribute path escapes associated root")
            _require(isinstance(attrs, dict), "Metadata.plist value not a dictionary")
    return {
        "has_keychain": "Keychain.plist" in local_names,
        "has_metadata": "Metadata.plist" in local_names,
        "associated_entries": seen_data,
    }


def _verify_non_keychain_payloads(
    zf: zipfile.ZipFile,
    members: dict[str, zipfile.ZipInfo],
    keychain_names: set[str],
) -> int:
    """Opt-in bounded CRC validation, WITHOUT reading Keychain.plist data.

    Count the budget BEFORE reading so an oversized archive never gets a
    misleading partially-verified status. ZIP readers check each CRC on EOF.
    """
    total_to_read = sum(item.file_size for name, item in members.items()
                        if name not in keychain_names and not item.is_dir())
    if total_to_read > MAX_VERIFY_BYTES:
        raise UnsupportedArchive("non-Keychain payload exceeds CRC inspection budget")
    checked = 0
    for name, item in members.items():
        if name in keychain_names or item.is_dir():
            continue
        try:
            with zf.open(item, "r") as stream:
                length = 0
                while True:
                    chunk = stream.read(VERIFY_CHUNK_BYTES)
                    if not chunk:
                        break
                    length += len(chunk)
                    if length > item.file_size or checked + length > MAX_VERIFY_BYTES:
                        raise InvalidArchive("ZIP payload exceeded advertised byte count")
                _require(length == item.file_size,
                         "ZIP member length differs from central directory")
                checked += length
        except (zipfile.BadZipFile, EOFError, RuntimeError,
                OSError, ValueError, zlib.error) as exc:
            raise InvalidArchive("corrupted ZIP payload or local header") from exc
    return checked


def inspect_archive(path: str | os.PathLike[str],
                    *, verify_payload: bool = False) -> dict[str, Any]:
    archive = Path(path)
    extension = archive.suffix.lower()
    _require(extension in (".cranect", ".cranebk"),
             "expected .cranect (single) or .cranebk (multi)")
    _require(archive.is_file(), "backup file does not exist")
    kind = "multi" if extension == ".cranebk" else "single"
    try:
        with zipfile.ZipFile(archive, "r", allowZip64=True) as zf:
            members = zf.infolist()
            if len(members) > MAX_MEMBERS:
                raise UnsupportedArchive("too many ZIP members for bounded inspection")
            names: dict[str, zipfile.ZipInfo] = {}
            folded: set[str] = set()
            total = 0
            has_encrypted = False
            for item in members:
                name = _safe_member_name(item.filename)
                folded_name = name.casefold()
                _require(folded_name not in folded, "duplicate or case-colliding ZIP entry")
                folded.add(folded_name)
                _require(item.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                         f"unsupported ZIP compression: {item.filename}")
                if item.create_system == 3:
                    filetype = stat.S_IFMT(item.external_attr >> 16)
                    _require(filetype not in (stat.S_IFLNK, stat.S_IFCHR,
                             stat.S_IFBLK, stat.S_IFIFO, stat.S_IFSOCK),
                             f"special file or symlink in ZIP: {item.filename}")
                    if item.is_dir():
                        _require(filetype in (0, stat.S_IFDIR),
                                 "directory name conflicts with Unix type")
                    else:
                        _require(filetype in (0, stat.S_IFREG),
                                 "file name conflicts with Unix type")
                if item.is_dir():
                    _require(item.file_size == 0, "nonempty ZIP directory")
                else:
                    if item.file_size > MAX_MEMBER_SIZE:
                        raise UnsupportedArchive("ZIP member exceeds conservative size limit")
                    if item.compress_size == 0 and item.file_size:
                        raise UnsupportedArchive("zero compressed length for nonempty file")
                    if (item.compress_size and
                        item.file_size > MAX_COMPRESSION_RATIO * item.compress_size):
                        raise UnsupportedArchive("ZIP compression ratio exceeds safety bound")
                total += item.file_size
                if total > MAX_TOTAL_SIZE:
                    raise UnsupportedArchive("ZIP total uncompressed size exceeds safety bound")
                if item.flag_bits & 0x1:
                    has_encrypted = True
                names[name] = item

            for name in names:
                parts = name.split("/")
                for depth in range(1, len(parts)):
                    parent = "/".join(parts[:depth])
                    if parent in names:
                        _require(names[parent].is_dir(),
                                 f"ZIP file shadows parent directory: {parent}")

            # ZIP password encryption blocks metadata inspection; do not ask
            # the caller for credentials or report a false 'valid' archive.
            if has_encrypted:
                raise UnsupportedArchive(
                    "encrypted ZIP requires separate password-aware inspector; not validated")

            _require("Info.plist" in names and not names["Info.plist"].is_dir(),
                     "missing root Info.plist")
            root_info = _read_small_plist(zf, names["Info.plist"])
            results: list[dict[str, Any]] = []

            if kind == "single":
                _require("containedContainers" not in root_info,
                         "multi index with .cranect extension")
                app, container, ids = _validate_info(root_info)
                payload = _check_payload(zf, names, "", ids)
                results.append({"application_identifier": app,
                                "container_identifier": container, **payload})
            else:
                summaries = root_info.get("containedContainers")
                _require(isinstance(summaries, list) and 0 < len(summaries) <= 10000,
                         "missing/invalid multi containedContainers index")
                identifiers: set[tuple[str, str]] = set()
                for summary in summaries:
                    _require(isinstance(summary, dict), "container index item is not dictionary")
                    app = _safe_id(summary.get("applicationIdentifier"),
                                   "multi applicationIdentifier")
                    cid = _safe_id(summary.get("containerIdentifier"),
                                   "multi containerIdentifier")
                    _require((app, cid) not in identifiers,
                             "repeated container in multi index")
                    identifiers.add((app, cid))
                    base = f"{app}/{cid}/"
                    member = base + "Info.plist"
                    _require(member in names and not names[member].is_dir(),
                             f"missing multi container Info.plist: {member}")
                    container_info = _read_small_plist(zf, names[member])
                    _, _, ids = _validate_info(container_info, app, cid)
                    payload = _check_payload(zf, names, base, ids)
                    results.append({"application_identifier": app,
                                    "container_identifier": cid, **payload})
                # Reject undeclared containers or unexpected files at root.
                expected_prefixes = [f"{app}/{cid}/" for app, cid in identifiers]
                all_app_dirs = {app for app, _ in identifiers}
                for name, item in names.items():
                    if name == "Info.plist":
                        continue
                    if item.is_dir() and (name in all_app_dirs or
                        any(name == f"{app}/{cid}" for app, cid in identifiers)):
                        continue
                    _require(any(name.startswith(prefix) for prefix in expected_prefixes),
                             f"ZIP entry outside multi index: {name}")

            # Keychain contents must never be opened/read by this tool.
            keychain_names = (
                ({"Keychain.plist"} if "Keychain.plist" in names else set())
                if kind == "single" else {
                    f"{item['application_identifier']}/{item['container_identifier']}/Keychain.plist"
                    for item in results
                    if f"{item['application_identifier']}/{item['container_identifier']}/Keychain.plist"
                    in names
                }
            )
            inspected_bytes = (_verify_non_keychain_payloads(
                zf, names, keychain_names) if verify_payload else 0)

            # Even an opt-in CRC pass is NOT an authenticity/restore proof.
            # With Keychain present, "payload_crc_verified" must stay false.
            return {"status": "structural_pass_not_verified", "kind": kind,
                    "containers": results, "member_count": len(members),
                    "uncompressed_bytes_claimed": total,
                    "payload_crc_verified": verify_payload and not keychain_names,
                    "non_keychain_payload_crc_verified": verify_payload,
                    "crc_checked_bytes": inspected_bytes,
                    "keychain_contents_read": False, "extracted": False}
    except (zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        raise InvalidArchive("not a readable ZIP central directory") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Read-only Crane archive structure inspection (NO restore/extraction)")
    parser.add_argument("archive", help="Original .cranect / .cranebk backup file")
    parser.add_argument("--verify-payload", action="store_true",
                        help="Stream/check CRC for non-Keychain members (max 256 MiB); never extract")
    args = parser.parse_args(argv)
    try:
        result = inspect_archive(args.archive, verify_payload=args.verify_payload)
        code = 0
    except UnsupportedArchive as exc:
        result, code = {"status": "unsupported_not_validated", "reason": str(exc)}, 2
    except (InvalidArchive, OSError) as exc:
        result, code = {"status": "invalid", "reason": str(exc)}, 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
