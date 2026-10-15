#!/usr/bin/env python3
"""G-11 D4: bounded archive-file materialization into a disposable TEMP lab ONLY.

This is an experiment using SYNTHETIC ZIPs emitted by the fixture writer.
The source backup must be inside the same double-marked temporary fixture.
The only output is a NEW quarantine directory; never replace existing data.
All selected containers are staged together then published by ONE directory
rename (not a native multi-container restore or power-loss guarantee).

DO NOT use this tool with iPhone data, real Crane backups or private files.
It does not apply Metadata.plist, Keychain, vendor ID, preferences rewrites,
or invoke CraneManager. None of its results authorize production restore.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import zipfile

from crane_backup_fixture_writer import MARKER, MARKER_CONTENT
from crane_backup_inspector import (
    InvalidArchive, UnsupportedArchive, _read_small_plist,
)
from crane_restore_preflight import (
    PreflightError, _inventory, _original_identifiers,
)
from crane_restore_work_plan import PlanError, plan_restore

LAB = "restore-materialize-lab"
LAB_MARKER = ".crane-materialize-lab"
LAB_MARKER_VALUE = b"CRANE_DISPOSABLE_MATERIALIZE_LAB_V1\n"
STAGE_MARKER = ".crane-stage"
STAGE_VALUE = b"CRANE_DISPOSABLE_STAGE_V1\n"
MAX_CONTAINERS = 2
MAX_FILES = 200
MAX_TOTAL_BYTES = 16 * 1024 * 1024
MAX_PATH_COMPONENT = 120
CHUNK = 1024 * 1024
FAILPOINTS = ("after_first_file", "before_publish")
RESERVED = {"con", "prn", "aux", "nul", "clock$"}
RESERVED.update(f"com{i}" for i in range(1, 10))
RESERVED.update(f"lpt{i}" for i in range(1, 10))


class MaterializeError(Exception):
    """Fixture guard or safe-staging invariant denied."""


class InjectedFault(MaterializeError):
    """An intentional staging failure to exercise lab rollback."""


def _need(ok: bool) -> None:
    if not ok:
        raise MaterializeError("unsafe or invalid disposable fixture")


def _ordinary_directory(path: Path) -> None:
    _need(not path.is_symlink() and path.is_dir() and
          stat.S_ISDIR(path.lstat().st_mode))


def _ordinary_file(path: Path, max_size: int) -> bytes:
    _need(not path.is_symlink())
    info = path.lstat()
    _need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and
          info.st_size <= max_size)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        _need((opened.st_dev, opened.st_ino, opened.st_size) ==
              (info.st_dev, info.st_ino, info.st_size))
        with os.fdopen(fd, "rb", closefd=False) as handle:
            data = handle.read(max_size + 1)
        _need(len(data) == info.st_size)
        return data
    finally:
        os.close(fd)


def _fixture_layout(root_argument: str | Path) -> tuple[Path, Path, Path]:
    arg = Path(root_argument).absolute()
    _need(not arg.is_symlink())
    root = arg.resolve(strict=True)
    _ordinary_directory(root)
    temporary = Path(tempfile.gettempdir()).resolve(strict=True)
    _need(root != temporary and temporary in root.parents)
    _need(_ordinary_file(root / MARKER, 128) == MARKER_CONTENT)
    lab = root / LAB
    _ordinary_directory(lab)
    _need(_ordinary_file(lab / LAB_MARKER, 128) == LAB_MARKER_VALUE)
    _need({p.name for p in lab.iterdir()} ==
          {LAB_MARKER, "staging", "published"})
    staging = lab / "staging"
    published = lab / "published"
    _ordinary_directory(staging)
    _ordinary_directory(published)
    return root, staging, published


def _source_path(root: Path, candidate: str | Path,
                 expected_directory: Path, name: str | None = None) -> Path:
    file = Path(candidate).absolute()
    _need(not file.is_symlink())
    _ordinary_directory(expected_directory)
    # No alternative source directories or attached local file paths.
    _need(file.parent.resolve(strict=True) == expected_directory)
    if name is not None:
        _need(file.name == name)
    _ordinary_file(file, MAX_TOTAL_BYTES + 1024 * 1024)
    return file


def _safe_component(value: str) -> None:
    """Portable subset only; valid original iOS names may be unsupported."""
    _need(0 < len(value) <= MAX_PATH_COMPONENT and
          re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._ -]*", value) is not None and
          not value.endswith((".", " ")) and
          value.split(".")[0].casefold() not in RESERVED)


def _write_exclusive(path: Path, stream: zipfile.ZipExtFile,
                     expected: int) -> None:
    _need(expected <= MAX_TOTAL_BYTES)
    flags = (os.O_WRONLY | os.O_CREAT | os.O_EXCL |
             getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0))
    fd = os.open(path, flags, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as handle:
            used = 0
            while True:
                part = stream.read(CHUNK)
                if not part:
                    break
                used += len(part)
                _need(used <= expected)
                handle.write(part)
            _need(used == expected)
            handle.flush()
            os.fsync(fd)
    finally:
        os.close(fd)


def _safe_stage_cleanup(stage: Path, staging: Path) -> None:
    _need(stage == staging / "batch" and not stage.is_symlink())
    _ordinary_directory(stage)
    _need(_ordinary_file(stage / STAGE_MARKER, 128) == STAGE_VALUE)
    # No symlinks/hardlinks or unknown top-level entries before recursive
    # deletion. Only the fixed single-use quarantine staging directory.
    for base, dirs, files in os.walk(stage, topdown=True, followlinks=False):
        for name in dirs + files:
            item = Path(base) / name
            _need(not item.is_symlink())
            mode = item.lstat().st_mode
            _need(stat.S_ISDIR(mode) or
                  (stat.S_ISREG(mode) and item.lstat().st_nlink == 1))
    shutil.rmtree(stage)


def materialize_fixture(
    fixture_root: str | Path,
    archive: str | Path,
    inventory: str | Path,
    *,
    inject_failure: str | None = None,
) -> dict[str, object]:
    _need(inject_failure is None or inject_failure in FAILPOINTS)
    root, staging, published = _fixture_layout(fixture_root)
    archive_path = _source_path(root, archive, root / "output")
    inventory_path = _source_path(root, inventory, root, "inventory.json")

    # No existing batch may be touched, and no incomplete staging auto-cleared
    # from an earlier interrupted process.
    _need(not list(staging.iterdir()) and not list(published.iterdir()))
    report = plan_restore(archive_path, inventory_path, verify_payload=True)
    _need(report["status"] == "work_plan_advisory_only")
    _need(report["restore_executable"] is False and
          report["non_keychain_crc_verified"] is True and
          report["original_compatibility_proven"] is False)
    _need(1 <= report["mapped_containers"] <= MAX_CONTAINERS and
          report["selected_payload_files"] <= MAX_FILES and
          report["selected_payload_bytes_claimed"] <= MAX_TOTAL_BYTES)

    selected, _ = _inventory(inventory_path)
    _need(len(selected) == report["mapped_containers"])
    stage = staging / "batch"
    destination = published / "batch"
    _need(not stage.exists() and not stage.is_symlink() and
          not destination.exists() and not destination.is_symlink())

    # Materialize original archive contents inside numeric, non-identifying
    # associated roots. No source originalPaths become destination paths.
    stage.mkdir()
    (stage / STAGE_MARKER).write_bytes(STAGE_VALUE)
    files_written = 0
    bytes_written = 0
    try:
        with zipfile.ZipFile(archive_path, "r") as zf:
            for index, mapping in enumerate(selected, 1):
                source = mapping["source"]
                prefix = (f"{source[0]}/{source[1]}/"
                          if report["archive_kind"] == "multi" else "")
                info = _read_small_plist(zf, zf.getinfo(prefix + "Info.plist"))
                associated = sorted(_original_identifiers(info, source[0]))
                numeric_ids = {name: i for i, name in enumerate(associated, 1)}
                container_root = stage / f"container-{index}"
                container_root.mkdir()
                for i in numeric_ids.values():
                    (container_root / f"associated-{i}").mkdir()
                for member in zf.infolist():
                    if not member.filename.startswith(prefix):
                        continue
                    relative = member.filename[len(prefix):].rstrip("/")
                    if relative in ("Info.plist", "Metadata.plist", "Keychain.plist"):
                        continue
                    parts = relative.split("/")
                    _need(parts[0] in numeric_ids)
                    for part in parts[1:]:
                        _safe_component(part)
                    target = container_root / f"associated-{numeric_ids[parts[0]]}"
                    for part in parts[1:-1]:
                        target /= part
                        target.mkdir(exist_ok=True)
                        _ordinary_directory(target)
                    if member.is_dir():
                        if len(parts) > 1:
                            (target / parts[-1]).mkdir(exist_ok=True)
                            _ordinary_directory(target / parts[-1])
                    else:
                        _need(len(parts) > 1)
                        files_written += 1
                        bytes_written += member.file_size
                        _need(files_written <= MAX_FILES and
                              bytes_written <= MAX_TOTAL_BYTES)
                        with zf.open(member, "r") as stream:
                            _write_exclusive(target / parts[-1],
                                             stream, member.file_size)
                        if inject_failure == "after_first_file" and files_written == 1:
                            raise InjectedFault("deliberate staging test failure")
        _need(files_written == report["selected_payload_files"] and
              bytes_written == report["selected_payload_bytes_claimed"])
        if inject_failure == "before_publish":
            raise InjectedFault("deliberate pre-publish test failure")
        # One rename publishes the entire collection, never replacing a
        # pre-existing destination; still NOT robust to a hostile race.
        _need(not destination.exists() and not destination.is_symlink())
        os.rename(stage, destination)
        return {
            "status": "fixture_materialized_not_restore",
            "containers": len(selected),
            "files": files_written,
            "bytes": bytes_written,
            "device_data_touched": False,
            "keychain_contents_read": False,
            "real_rollback_implemented": False,
            "restore_executable": False,
        }
    except Exception:
        # This lab only rolls back an UNPUBLISHED, newly created sandbox
        # stage. Never touch published/ or any preexisting app data.
        if stage.exists():
            _safe_stage_cleanup(stage, staging)
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Materialize SYNTHETIC Crane ZIP only into double-marked TEMP fixture, "
        "never an iPhone restore"))
    parser.add_argument("--fixture-root", required=True)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--inject-failure", choices=FAILPOINTS)
    args = parser.parse_args(argv)
    try:
        report = materialize_fixture(
            args.fixture_root, args.archive, args.inventory,
            inject_failure=args.inject_failure)
        exit_code = 0
    except InjectedFault:
        report, exit_code = ({
            "status": "fixture_stage_rolled_back",
            "restore_executable": False,
        }, 3)
    except (MaterializeError, PlanError, PreflightError, InvalidArchive,
            UnsupportedArchive, OSError, KeyError, ValueError, TypeError,
            RuntimeError, zipfile.BadZipFile):
        report, exit_code = ({
            "status": "fixture_invalid_or_unsafe",
            "restore_executable": False,
        }, 2)
    print(json.dumps(report, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
