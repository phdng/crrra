#!/usr/bin/env python3
"""G-11 D5: read-only verification of D4's SYNTHETIC quarantine output.

Compare bounded ZIP payloads to a prior D4 published batch via streaming
SHA-256 and exact directory/file membership. The double-marked fixture must
be a child of OS temp, with ZIP and inventory at fixed locations.

Never extracts, repairs, deletes, modifies or publishes anything. Never
follows output symlinks, opens Keychain or uses original container paths for
filesystem access. This is NOT a real iPhone restore verification mechanism,
archive authenticity proof or crash-safety guarantee.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import zipfile

from crane_backup_inspector import (
    InvalidArchive, UnsupportedArchive, _read_small_plist,
)
from crane_restore_preflight import (
    PreflightError, _inventory, _original_identifiers,
)
from crane_restore_work_plan import PlanError, _file_identity, plan_restore
from crane_restore_fixture_materializer import (
    CHUNK, LAB, MAX_CONTAINERS, MAX_FILES, MAX_TOTAL_BYTES,
    MaterializeError, STAGE_MARKER, STAGE_VALUE, _fixture_layout,
    _ordinary_file, _safe_component, _source_path,
)

MAX_TREE_ENTRIES = 8000


class VerifyError(Exception):
    """Unverifiable fixture or unsafe read request."""


def _require(ok: bool) -> None:
    if not ok:
        raise VerifyError("quarantine verification refused")


def _relative(parts: tuple[str, ...]) -> str:
    # Never serialize a path; only used internally to match ZIP structure.
    return "/".join(parts)


def _expect_from_zip(zf: zipfile.ZipFile, checked: dict,
                     chosen: list[dict]) -> tuple[set[str], dict[str, zipfile.ZipInfo]]:
    dirs: set[str] = set()
    files: dict[str, zipfile.ZipInfo] = {}
    for index, mapping in enumerate(chosen, 1):
        source = mapping["source"]
        prefix = (f"{source[0]}/{source[1]}/"
                  if checked["archive_kind"] == "multi" else "")
        info = _read_small_plist(zf, zf.getinfo(prefix + "Info.plist"))
        identities = sorted(_original_identifiers(info, source[0]))
        identifier_indexes = {name: i for i, name in enumerate(identities, 1)}
        container = f"container-{index}"
        dirs.add(container)
        for associated in identifier_indexes.values():
            dirs.add(f"{container}/associated-{associated}")

        for item in zf.infolist():
            if not item.filename.startswith(prefix):
                continue
            remainder = item.filename[len(prefix):].rstrip("/")
            if remainder in ("Info.plist", "Metadata.plist", "Keychain.plist"):
                continue
            parts = remainder.split("/")
            _require(parts[0] in identifier_indexes)
            for segment in parts[1:]:
                _safe_component(segment)
            _require(item.is_dir() or len(parts) > 1)
            path_parts = (container,
                          f"associated-{identifier_indexes[parts[0]]}",
                          *parts[1:])
            for cutoff in range(2, len(path_parts)):
                dirs.add(_relative(path_parts[:cutoff]))
            dest = _relative(path_parts)
            if item.is_dir():
                dirs.add(dest)
            else:
                _require(dest not in files)
                files[dest] = item
    _require(len(files) <= MAX_FILES and
             sum(item.file_size for item in files.values()) <= MAX_TOTAL_BYTES)
    _require(len(files) == checked["selected_payload_files"])
    _require(sum(item.file_size for item in files.values()) ==
             checked["selected_payload_bytes_claimed"])
    _require(len(dirs) + len(files) + 1 <= MAX_TREE_ENTRIES)
    _require(not (dirs & files.keys()))
    return dirs, files


def _observed_tree(batch: Path) -> tuple[set[str], dict[str, Path], set[str]]:
    dirs: set[str] = set()
    files: dict[str, Path] = {}
    flags: set[str] = set()
    visited = 0
    # Never follow symlinks or examine private contents of unexpected files.
    for base, folders, filenames in os.walk(batch, topdown=True, followlinks=False):
        parent = Path(base)
        for name in list(folders):
            visited += 1
            path = parent / name
            rel = _relative(path.relative_to(batch).parts)
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                flags.add("unsafe_directory_entry")
                folders.remove(name)
            else:
                dirs.add(rel)
        for name in filenames:
            visited += 1
            path = parent / name
            rel = _relative(path.relative_to(batch).parts)
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
                flags.add("unsafe_file_entry")
            elif path.lstat().st_nlink != 1:
                flags.add("linked_output_file")
            else:
                files[rel] = path
        if visited > MAX_TREE_ENTRIES:
            raise VerifyError("too many quarantine entries")
    return dirs, files, flags


def _digest_file(path: Path, advertised: int) -> bytes:
    if path.is_symlink():
        raise VerifyError("quarantine file is symlink")
    before = path.lstat()
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or
            before.st_size != advertised or advertised > MAX_TOTAL_BYTES):
        raise VerifyError("unsafe quarantine file metadata")
    flags = (os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) |
             getattr(os, "O_BINARY", 0))
    descriptor = os.open(path, flags)
    try:
        actual = os.fstat(descriptor)
        if ((actual.st_dev, actual.st_ino, actual.st_size) !=
                (before.st_dev, before.st_ino, before.st_size) or
                actual.st_nlink != 1 or not stat.S_ISREG(actual.st_mode)):
            raise VerifyError("quarantine file changed before reading")
        digest = hashlib.sha256()
        length = 0
        while True:
            chunk = os.read(descriptor, min(CHUNK, advertised - length + 1))
            if not chunk:
                break
            length += len(chunk)
            if length > advertised:
                raise VerifyError("quarantine file exceeds claimed bytes")
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (length != advertised or after.st_size != advertised or
                after.st_mtime_ns != before.st_mtime_ns):
            raise VerifyError("quarantine file changed during verification")
        return digest.digest()
    finally:
        os.close(descriptor)


def _digest_member(zf: zipfile.ZipFile, member: zipfile.ZipInfo) -> bytes:
    digest = hashlib.sha256()
    consumed = 0
    with zf.open(member, "r") as stream:
        while True:
            piece = stream.read(CHUNK)
            if not piece:
                break
            consumed += len(piece)
            if consumed > member.file_size:
                raise VerifyError("ZIP member length changed")
            digest.update(piece)
    if consumed != member.file_size:
        raise VerifyError("ZIP member truncated")
    return digest.digest()


def verify_quarantine(fixture_root: str | Path, archive: str | Path,
                      inventory: str | Path) -> dict[str, object]:
    root, staging, published = _fixture_layout(fixture_root)
    path = _source_path(root, archive, root / "output")
    manifest = _source_path(root, inventory, root, "inventory.json")
    initial_archive = _file_identity(path)
    initial_inventory = _file_identity(manifest)
    _require(not list(staging.iterdir()))
    _require({p.name for p in published.iterdir()} == {"batch"})
    batch = published / "batch"
    _require(not batch.is_symlink() and batch.is_dir() and
             stat.S_ISDIR(batch.lstat().st_mode))

    # Re-check against the explicit D0/D3 inventory, NOT actual device
    # identity. No user-supplied filesystem path becomes a destination.
    checked = plan_restore(path, manifest, verify_payload=True)
    _require(checked["status"] == "work_plan_advisory_only" and
             checked["restore_executable"] is False and
             checked["non_keychain_crc_verified"] is True)
    _require(1 <= checked["mapped_containers"] <= MAX_CONTAINERS and
             checked["selected_payload_files"] <= MAX_FILES and
             checked["selected_payload_bytes_claimed"] <= MAX_TOTAL_BYTES)
    chosen, _ = _inventory(manifest)
    _require(len(chosen) == checked["mapped_containers"])

    with zipfile.ZipFile(path, "r") as zf:
        wanted_dirs, wanted_files = _expect_from_zip(zf, checked, chosen)
        actual_dirs, actual_files, errors = _observed_tree(batch)

        if _ordinary_file(batch / STAGE_MARKER, 128) != STAGE_VALUE:
            errors.add("marker_invalid")
        # Remove the internal stage sentinel before file set comparison.
        actual_files.pop(STAGE_MARKER, None)

        missing_dirs = wanted_dirs - actual_dirs
        extra_dirs = actual_dirs - wanted_dirs
        missing_files = wanted_files.keys() - actual_files.keys()
        extra_files = actual_files.keys() - wanted_files.keys()
        if missing_dirs:
            errors.add("missing_directories")
        if extra_dirs:
            errors.add("unexpected_directories")
        if missing_files:
            errors.add("missing_files")
        if extra_files:
            errors.add("unexpected_files")

        checked_files = 0
        corrupt = 0
        for relative, member in wanted_files.items():
            if relative not in actual_files:
                continue
            try:
                actual_digest = _digest_file(actual_files[relative],
                                             member.file_size)
                zip_digest = _digest_member(zf, member)
                checked_files += 1
                if actual_digest != zip_digest:
                    corrupt += 1
            except (VerifyError, OSError, zipfile.BadZipFile, EOFError,
                    RuntimeError, ValueError):
                corrupt += 1
        if corrupt:
            errors.add("file_content_or_length_mismatch")

    # ZIP/inventory are reopened by D3 and this verifier. A changed file
    # invalidates the run even if its old ZIP central index was still cached.
    # Stat equality is only a best-effort guard, not a hostile-race proof.
    if (_file_identity(path) != initial_archive or
            _file_identity(manifest) != initial_inventory):
        raise VerifyError("fixture input changed during verification")

    return {
        "status": ("fixture_verified_read_only" if not errors
                   else "fixture_integrity_mismatch"),
        "reason_codes": sorted(errors),
        "expected_files": len(wanted_files),
        "expected_directories": len(wanted_dirs),
        "files_hashed": checked_files,
        "mismatched_files": corrupt,
        "missing_files": len(missing_files),
        "unexpected_files": len(extra_files),
        "missing_directories": len(missing_dirs),
        "unexpected_directories": len(extra_dirs),
        "device_data_touched": False,
        "keychain_contents_read": False,
        "filesystem_writes": False,
        "original_compatibility_proven": False,
        "real_rollback_implemented": False,
        "restore_executable": False,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Verify D4 synthetic quarantine against its ZIP, read-only; "
        "not native Crane restore or data-authenticity proof"))
    parser.add_argument("--fixture-root", required=True)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--inventory", required=True)
    args = parser.parse_args(argv)
    try:
        report = verify_quarantine(
            args.fixture_root, args.archive, args.inventory)
        code = 0 if report["status"] == "fixture_verified_read_only" else 1
    except (VerifyError, MaterializeError, PlanError, PreflightError,
            InvalidArchive, UnsupportedArchive, OSError, ValueError,
            TypeError, KeyError, RuntimeError, zipfile.BadZipFile):
        # Never echo exceptions: names/IDs/originalPaths may be sensitive.
        report = {"status": "fixture_verify_invalid_or_unavailable",
                  "restore_executable": False}
        code = 2
    print(json.dumps(report, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
