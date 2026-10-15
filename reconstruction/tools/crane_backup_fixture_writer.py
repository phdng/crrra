#!/usr/bin/env python3
"""G-11 Stage B: OFFLINE DISPOSABLE-FIXTURE Crane-shaped ZIP writer.

Not a Crane-compatible backup implementation until original fixture evidence
proves byte-level parity. Never targets iPhone containers, Keychain or helperd.
Writes only inside an explicitly marked disposable directory, without overwrite.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import uuid
import zipfile

from crane_backup_inspector import (
    InvalidArchive, UnsupportedArchive, _safe_id, _safe_member_name,
    _safe_original_path, inspect_archive,
)
from crane_backup_metadata import (attributes_available_from_stat,
                                   original_sample_shape_synthetic_attributes)

MARKER = ".crane-disposable-fixture"
MARKER_CONTENT = b"CRANE_DISPOSABLE_FIXTURE_V1\n"
MAX_INPUT_FILES = 5000
MAX_FILE_SIZE = 32 * 1024 * 1024
MAX_INPUT_SIZE = 128 * 1024 * 1024
CHUNK = 1024 * 1024


class FixtureError(ValueError):
    """A fixture is unsafe or cannot be represented in this experiment."""


def _ensure(condition: bool, message: str) -> None:
    if not condition:
        raise FixtureError(message)


def _inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _fixture_root(path: str | os.PathLike[str]) -> Path:
    input_path = Path(path).absolute()
    _ensure(not input_path.is_symlink(), "fixture root is symlink")
    root = input_path.resolve(strict=True)
    _ensure(root.is_dir() and root.parent != root,
            "fixture root must be an existing directory")
    marker = root / MARKER
    _ensure(not marker.is_symlink() and marker.is_file() and
            marker.stat().st_size == len(MARKER_CONTENT) and
            marker.read_bytes() == MARKER_CONTENT,
            "fixture marker missing or invalid (never operate on real containers)")
    return root


def _safe_relative(path: str) -> Path:
    _ensure(isinstance(path, str) and bool(path) and len(path) <= 1024,
            "invalid fixture-relative source")
    try:
        _safe_member_name(path)
    except InvalidArchive as exc:
        raise FixtureError("unsafe fixture source path") from exc
    _ensure(not path.endswith("/") and not path.startswith("output/") and
            path not in ("output", MARKER),
            "fixture source includes reserved output/marker path")
    return Path(*path.split("/"))


def _verify_regular(root: Path, relative: Path, is_folder: bool) -> Path:
    path = root
    for element in relative.parts:
        path = path / element
        _ensure(not path.is_symlink(), "symlink in fixture source path")
        _ensure(_inside(path.resolve(strict=True), root),
                "fixture source escapes disposable root")
    mode = path.lstat().st_mode
    _ensure(stat.S_ISDIR(mode) if is_folder else stat.S_ISREG(mode),
            "source is not expected directory/regular file")
    return path


def _load_manifest(root: Path, name: str) -> list[dict]:
    relative = _safe_relative(name)
    manifest_file = _verify_regular(root, relative, False)
    _ensure(manifest_file.stat().st_size <= 256 * 1024, "fixture manifest too large")
    try:
        document = json.loads(manifest_file.read_text(encoding="utf-8"))
    except (UnicodeError, ValueError, OSError) as exc:
        raise FixtureError("invalid fixture manifest JSON") from exc
    _ensure(isinstance(document, dict) and set(document) == {"containers"},
            "manifest must contain only containers")
    containers = document["containers"]
    _ensure(isinstance(containers, list) and 1 <= len(containers) <= 50,
            "fixture requires 1-50 container records")
    seen: set[tuple[str, str]] = set()
    output: list[dict] = []
    for item in containers:
        _ensure(isinstance(item, dict) and
                set(item) == {"applicationIdentifier", "containerIdentifier",
                              "containerName", "originalPaths", "sourceDirectories"},
                "unsupported fixture options (password/Keychain not supported)")
        try:
            app = _safe_id(item["applicationIdentifier"], "app ID")
            cid = _safe_id(item["containerIdentifier"], "container ID")
        except InvalidArchive as exc:
            raise FixtureError("invalid fixture container identifiers") from exc
        _ensure((app, cid) not in seen, "duplicate fixture app/container pair")
        seen.add((app, cid))
        name = item["containerName"]
        _ensure(isinstance(name, str) and len(name) <= 1024,
                "invalid fixture containerName")
        originals, sources = item["originalPaths"], item["sourceDirectories"]
        _ensure(isinstance(originals, dict) and originals and
                isinstance(sources, dict) and sources and
                set(originals) == set(sources),
                "originalPaths and sourceDirectories must cover same associated IDs")
        folded: set[str] = set()
        source_map: dict[str, Path] = {}
        for associated_id in originals:
            try:
                identifier = _safe_id(associated_id, "associated ID")
                _safe_original_path(originals[associated_id])
            except InvalidArchive as exc:
                raise FixtureError("invalid originalPaths mapping") from exc
            _ensure(identifier.casefold() not in
                    {"info.plist", "metadata.plist", "keychain.plist"},
                    "associated ID collides with reserved Crane ZIP metadata")
            _ensure(identifier.casefold() not in folded,
                    "duplicate case-folded associated IDs")
            folded.add(identifier.casefold())
            rel = _safe_relative(sources[identifier])
            source_map[identifier] = _verify_regular(root, rel, True)
        output.append({"applicationIdentifier": app, "containerIdentifier": cid,
                       "containerName": name, "originalPaths": originals,
                       "sources": source_map})
    return output


def _scan_sources(root: Path, containers: list[dict], multi: bool,
                  metadata_profile: str = "host-stat"):
    """List only fixture entries, fail before writing when unsafe."""
    _ensure(metadata_profile in ("host-stat", "synthetic-original-eight-field"),
            "unsupported test-only metadata profile")
    attribute_provider = (original_sample_shape_synthetic_attributes
                          if metadata_profile == "synthetic-original-eight-field"
                          else attributes_available_from_stat)
    items: list[tuple[str, Path | None, int]] = []
    metadata_by_container: list[dict] = []
    folded_names: set[str] = set()
    total = 0

    def add(name: str, path: Path | None, size: int) -> None:
        nonlocal total
        try:
            normalized = _safe_member_name(name)
        except InvalidArchive as exc:
            raise FixtureError("unsafe ZIP member name") from exc
        _ensure(normalized.casefold() not in folded_names,
                "case-colliding ZIP members")
        folded_names.add(normalized.casefold())
        total += size
        _ensure(len(items) < MAX_INPUT_FILES and total <= MAX_INPUT_SIZE,
                "fixture exceeds conservative file/byte limit")
        items.append((name, path, size))

    for container in containers:
        prefix = (f"{container['applicationIdentifier']}/"
                  f"{container['containerIdentifier']}/") if multi else ""
        attributes: dict[str, dict] = {}
        for identifier, directory in sorted(container["sources"].items()):
            # Original SSZipArchive's enumerator places associated content
            # under its path identifier, including empty directories.
            pending = [(directory, identifier)]
            while pending:
                source, relative = pending.pop()
                source = _verify_regular(root, source.relative_to(root), True)
                # Original 0x24948 applies CRPBackupContainer's twelve-key
                # writable filter to NSFileManager attributes for each item.
                attributes[relative] = attribute_provider(source.lstat())
                add(prefix + relative + "/", None, 0)
                children = sorted(os.scandir(source), key=lambda e: e.name,
                                  reverse=True)
                for child in children:
                    _ensure(not child.is_symlink(), "symlink in fixture tree")
                    child_path = Path(child.path)
                    child_relative = relative + "/" + child.name
                    _ensure(_inside(child_path.resolve(strict=True), root),
                            "fixture child escapes source root")
                    mode = child.stat(follow_symlinks=False).st_mode
                    if stat.S_ISDIR(mode):
                        pending.append((child_path, child_relative))
                    elif stat.S_ISREG(mode):
                        _ensure(child.stat(follow_symlinks=False).st_nlink <= 1,
                                "hardlink is not accepted in fixture data")
                        size = child.stat(follow_symlinks=False).st_size
                        _ensure(size <= MAX_FILE_SIZE, "fixture file too large")
                        attributes[child_relative] = attribute_provider(
                            child_path.lstat())
                        add(prefix + child_relative, child_path, size)
                    else:
                        raise FixtureError("nonregular fixture object")
        metadata_by_container.append(attributes)
    return items, metadata_by_container


def _plist_bytes(value: dict) -> bytes:
    content = plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True)
    _ensure(len(content) <= 2 * 1024 * 1024, "binary plist exceeds inspector limit")
    return content


def _zip_entry(name: str, *, is_directory: bool,
               zip_layout: str) -> str | zipfile.ZipInfo:
    """Opt-in only: preserve observed method and macOS ZIP creator.

    Python's zipfile cannot promise original SSZipArchive flag/ZIP64 layout.
    Do not set unverified flags or spoof full original compatibility.
    """
    if zip_layout != "original-observed-structure":
        return name
    info = zipfile.ZipInfo(name)
    info.create_system = 19
    info.compress_type = (zipfile.ZIP_STORED if is_directory
                          else zipfile.ZIP_DEFLATED)
    return info


def _write_file(zf: zipfile.ZipFile, name: str, source: Path,
                expected_size: int, root: Path,
                zip_layout: str = "standard") -> None:
    # Open with O_NOFOLLOW where supported; fstat before/after to reject
    # source swapping or concurrent modifications during the experiment.
    _verify_regular(root, source.relative_to(root), False)
    before = source.lstat()
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(source, flags)
    try:
        opened = os.fstat(fd)
        _ensure((opened.st_dev, opened.st_ino, opened.st_size) ==
                (before.st_dev, before.st_ino, expected_size),
                "fixture file changed during scan")
        _ensure(stat.S_ISREG(opened.st_mode) and opened.st_nlink <= 1,
                "opened fixture file is unsafe")
        with os.fdopen(fd, "rb", closefd=False) as reader:
            with zf.open(_zip_entry(name, is_directory=False,
                                    zip_layout=zip_layout), "w",
                         force_zip64=False) as destination:
                amount = 0
                while True:
                    data = reader.read(CHUNK)
                    if not data:
                        break
                    amount += len(data)
                    _ensure(amount <= expected_size,
                            "source increased in size during write")
                    destination.write(data)
                _ensure(amount == expected_size, "fixture source truncated")
        after = os.fstat(fd)
        _ensure(after.st_size == expected_size and
                after.st_mtime_ns == before.st_mtime_ns,
                "fixture source changed during write")
    finally:
        os.close(fd)


def write_fixture(root_path: str | os.PathLike[str], *,
                  manifest_name: str, output_name: str,
                  metadata_profile: str = "host-stat",
                  zip_layout: str = "standard") -> dict:
    root = _fixture_root(root_path)
    _ensure(isinstance(output_name, str) and
            0 < len(output_name) <= 255 and
            output_name == Path(output_name).name and
            not output_name.startswith(".") and
            not any(c in output_name for c in ("/", "\\", ":")) and
            all(32 <= ord(c) != 127 for c in output_name) and
            output_name.endswith((".cranect", ".cranebk")),
            "output must be a simple .cranect or .cranebk filename")
    _ensure(zip_layout in ("standard", "original-observed-structure"),
            "unsupported ZIP fixture layout")
    multi = output_name.endswith(".cranebk")
    _ensure(zip_layout != "original-observed-structure" or not multi,
            "observed ZIP envelope only applies to original single backups")
    containers = _load_manifest(root, manifest_name)
    _ensure(multi or len(containers) == 1,
            "single container filename requires exactly one container")
    # No automatic directory creation or arbitrary destination choices.
    output_dir = _verify_regular(root, Path("output"), True)
    target = output_dir / output_name
    _ensure(not target.exists() and not target.is_symlink(),
            "refusing to overwrite an existing output")
    entries, metas = _scan_sources(root, containers, multi,
                                   metadata_profile=metadata_profile)
    staging = output_dir / ("." + uuid.uuid4().hex + "." + output_name)
    result = None
    try:
        # 'x' exclusive mode for temp staging; never mutate an existing file.
        with zipfile.ZipFile(staging, mode="x",
                             compression=zipfile.ZIP_DEFLATED,
                             compresslevel=6, allowZip64=True) as zf:
            for idx, container in enumerate(containers):
                prefix = (f"{container['applicationIdentifier']}/"
                          f"{container['containerIdentifier']}/") if multi else ""
                info = {field: container[field] for field in (
                    "applicationIdentifier", "containerIdentifier",
                    "containerName", "originalPaths")}
                zf.writestr(_zip_entry(prefix + "Info.plist",
                                       is_directory=False,
                                       zip_layout=zip_layout),
                            _plist_bytes(info))
                if metas[idx] and zip_layout != "original-observed-structure":
                    zf.writestr(prefix + "Metadata.plist",
                                _plist_bytes(metas[idx]))
            for name, path, size in entries:
                if path is None:
                    zf.writestr(_zip_entry(name, is_directory=True,
                                           zip_layout=zip_layout), b"")
                elif size == 0:
                    zf.writestr(_zip_entry(name, is_directory=False,
                                           zip_layout=zip_layout), b"")
                else:
                    _write_file(zf, name, path, size, root,
                                zip_layout=zip_layout)
            if zip_layout == "original-observed-structure" and metas[0]:
                # Confirmed on user-provided original single .cranect:
                # Info first, payload next, Metadata last (not on multi).
                zf.writestr(_zip_entry("Metadata.plist", is_directory=False,
                                       zip_layout=zip_layout),
                            _plist_bytes(metas[0]))
            if multi:
                index = {"containedContainers": [
                    {key: container[key] for key in (
                        "applicationIdentifier", "containerIdentifier",
                        "containerName")}
                    for container in containers]}
                zf.writestr("Info.plist", _plist_bytes(index))

        # Re-check an output by the independent read-only implementation.
        checked = inspect_archive(staging, verify_payload=True)
        _ensure(checked["payload_crc_verified"] and
                len(checked["containers"]) == len(containers),
                "fixture writer output failed read-only ZIP verification")
        # os.link is create-new-only on both NTFS and POSIX: never replace the
        # destination even if another process created it during the scan.
        os.link(staging, target)
        result = {"status": "synthetic_fixture_only_not_original_compatible",
                  "kind": "multi" if multi else "single",
                  "containers": len(containers), "members": checked["member_count"],
                  "verified_bytes": checked["crc_checked_bytes"],
                  "metadata_profile": metadata_profile,
                  "zip_layout": zip_layout,
                  "original_zip_envelope_proven": False,
                  "original_compatibility_proven": False,
                  "output": str(target)}
        return result
    except (InvalidArchive, UnsupportedArchive) as exc:
        raise FixtureError("fixture ZIP did not pass read-only inspector") from exc
    finally:
        # Only clean this invocation's unique staging path, never the target.
        if staging.exists():
            staging.unlink()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Create synthetic Crane-shaped ZIP from EXPLICIT disposable fixture only; "
        "not a production backup/restore tool"))
    parser.add_argument("--fixture-root", required=True,
                        help="directory containing .crane-disposable-fixture sentinel")
    parser.add_argument("--manifest", default="manifest.json",
                        help="fixture-relative JSON manifest")
    parser.add_argument("--output", required=True,
                        help="basename inside pre-existing fixture/output/ directory")
    parser.add_argument("--zip-layout", default="standard",
                        choices=("standard", "original-observed-structure"),
                        help="Experimental single-container ZIP ordering/methods/creator; "
                             "SSZipArchive ZIP64/flags parity NOT proven")
    parser.add_argument("--metadata-profile", default="host-stat",
                        choices=("host-stat", "synthetic-original-eight-field"),
                        help="EXPLICIT fake 8-key schema for disposable fixture only; "
                             "not real iOS UID/GID/dates or original compatibility")
    args = parser.parse_args(argv)
    try:
        result = write_fixture(args.fixture_root,
                               manifest_name=args.manifest,
                               output_name=args.output,
                               metadata_profile=args.metadata_profile,
                               zip_layout=args.zip_layout)
    except (FixtureError, OSError, ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        print(json.dumps({"status": "fixture_failed", "reason": str(exc)}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
