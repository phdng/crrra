#!/usr/bin/env python3
"""N4 read-only independent check of native OS-temp dummy source ZIP.

Only accepts the exact documented fake app/test bytes, never a real user
archive. Compares native metadata values with source file stat/getpwuid/getgrgid
on macOS, and uses Python zipfile to independently check all payload CRCs.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
try:
    import pwd
    import grp
except ImportError:  # Windows CI-side unit tests only; native verification is macOS
    pwd = None
    grp = None
import stat
import sys
import tempfile
import zipfile


APP = "com.example.crane.native"
MARKER = b"CRANE_DISPOSABLE_FIXTURE_V1\n"
EXPECTED = {
    "Info.plist": None,
    APP + "/": None,
    APP + "/Library/": None,
    APP + "/Library/Preferences/": None,
    APP + "/nested/": None,
    APP + "/Library/Preferences/settings.bin": b"DUMMY-SOURCE-METADATA-ONLY\n",
    APP + "/nested/child.dat": b"FAKE-NESTED",
    APP + "/zero.txt": b"",
    "Metadata.plist": None,
}
METADATA_KEYS = {
    "NSFileCreationDate", "NSFileModificationDate",
    "NSFileOwnerAccountID", "NSFileOwnerAccountName",
    "NSFileGroupOwnerAccountID", "NSFileGroupOwnerAccountName",
    "NSFilePosixPermissions",
}


class InvalidNativeFixture(ValueError):
    pass


def _date_seconds(value: datetime) -> float:
    if not isinstance(value, datetime):
        raise InvalidNativeFixture("wrong time type")
    return value.replace(tzinfo=timezone.utc).timestamp()


def verify_collector_fixture(root_text: str | Path) -> dict:
    root = Path(root_text)
    if root.is_symlink() or not root.is_dir():
        raise InvalidNativeFixture("root not a real directory")
    root = root.resolve(strict=True)
    temp = Path(tempfile.gettempdir()).resolve(strict=True)
    if temp not in root.parents:
        raise InvalidNativeFixture("outside OS temp")
    if (root / ".crane-disposable-fixture").read_bytes() != MARKER:
        raise InvalidNativeFixture("missing marker")
    app_root = root / "source" / APP
    if app_root.is_symlink() or not app_root.is_dir():
        raise InvalidNativeFixture("not a disposable source")
    archive = root / "output" / "native-single.cranect"
    if archive.is_symlink() or not archive.is_file() or archive.stat().st_size > 2*1024*1024:
        raise InvalidNativeFixture("not a native fixture output")

    with zipfile.ZipFile(archive) as zf:
        entries = zf.infolist()
        names = [item.filename for item in entries]
        if set(names) != set(EXPECTED) or len(names) != len(EXPECTED):
            raise InvalidNativeFixture("unexpected ZIP entry count/paths")
        if names[0] != "Info.plist" or names[-1] != "Metadata.plist":
            raise InvalidNativeFixture("incorrect Info/Metadata ordering")
        for item in entries:
            if item.create_system != 19 or item.flag_bits != 0x0808 or (
                    item.extract_version != 45):
                raise InvalidNativeFixture("ZIP envelope differs from fixture shape")
            if item.compress_type != (zipfile.ZIP_STORED if item.is_dir()
                                      else zipfile.ZIP_DEFLATED):
                raise InvalidNativeFixture("unexpected ZIP method")
        if zf.testzip() is not None:
            raise InvalidNativeFixture("ZIP payload CRC mismatch")
        for name, expected in EXPECTED.items():
            if expected is not None and zf.read(name) != expected:
                raise InvalidNativeFixture("fake payload differs")

        info = plistlib.loads(zf.read("Info.plist"))
        if (info.get("applicationIdentifier") != APP or
                info.get("containerIdentifier") !=
                "00000000-0000-4000-8000-000000000001" or
                info.get("deviceIdentifierForVendor") !=
                "00000000-0000-4000-8000-000000000002"):
            raise InvalidNativeFixture("wrong synthetic identity")
        metadata = plistlib.loads(zf.read("Metadata.plist"))
        relative = set(EXPECTED) - {"Info.plist", "Metadata.plist"}
        required = {name.rstrip("/") for name in relative}
        if set(metadata) != required:
            raise InvalidNativeFixture("metadata must cover each source entry")

        if pwd is None or grp is None:
            raise InvalidNativeFixture("macOS POSIX account lookup unavailable")
        for member in relative:
            rel = member[len(APP):].strip("/")
            source = app_root / rel if rel else app_root
            if source.is_symlink() or not source.exists():
                raise InvalidNativeFixture("source changed")
            mode = source.stat(follow_symlinks=False)
            if member.endswith("/") and not stat.S_ISDIR(mode.st_mode):
                raise InvalidNativeFixture("directory type changed")
            if not member.endswith("/") and not stat.S_ISREG(mode.st_mode):
                raise InvalidNativeFixture("file type changed")
            props = metadata[member.rstrip("/")]
            if set(props) != METADATA_KEYS:
                raise InvalidNativeFixture("native stat-backed attributes incomplete")
            if props["NSFilePosixPermissions"] != stat.S_IMODE(mode.st_mode):
                raise InvalidNativeFixture("permissions mismatch")
            if props["NSFileOwnerAccountID"] != mode.st_uid or (
                    props["NSFileGroupOwnerAccountID"] != mode.st_gid):
                raise InvalidNativeFixture("owner identifiers differ")
            if props["NSFileOwnerAccountName"] != pwd.getpwuid(mode.st_uid).pw_name or (
                    props["NSFileGroupOwnerAccountName"] !=
                    grp.getgrgid(mode.st_gid).gr_name):
                raise InvalidNativeFixture("owner names differ")
            for key, second in (
                ("NSFileModificationDate", mode.st_mtime),
                ("NSFileCreationDate", getattr(mode, "st_birthtime", mode.st_ctime)),
            ):
                if abs(_date_seconds(props[key]) - second) > 1.05:
                    raise InvalidNativeFixture("native file timestamps differ")
    return {
        "status": "disposable_native_file_metadata_and_crc_match",
        "entryCount": len(EXPECTED),
        "metadataRecordCount": len(EXPECTED)-2,
        "payloadCRCVerified": True,
        "originalCompatibilityProven": False,
        "keychainContentsRead": False,
        "productionBackupAvailable": False,
        "restoreExecutable": False,
        "filesystemWrites": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture-root", required=True)
    args = parser.parse_args()
    try:
        result = verify_collector_fixture(args.fixture_root)
        code = 0
    except (InvalidNativeFixture, OSError, ValueError, KeyError, TypeError,
            RuntimeError, zipfile.BadZipFile, plistlib.InvalidFileException):
        result = {"status": "native_disposable_source_fixture_rejected",
                  "productionBackupAvailable": False, "restoreExecutable": False}
        code = 2
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
