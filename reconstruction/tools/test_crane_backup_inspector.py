"""Synthetic, isolated fixtures for the read-only Crane archive inspector.

No original user archives are stored in CI; these samples model the confirmed
CranePrefs binary-plist schema, NOT a verified byte-identical original backup.
"""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from unittest import mock

import crane_backup_inspector as inspector

from crane_backup_inspector import (
    InvalidArchive, UnsupportedArchive, inspect_archive,
)

APP = "com.example.cranefixture"
CID = "B7A18062-2CEB-4D7D-B8A3-33EEB36A0E01"
APP2 = "org.example.secondfixture"
CID2 = "C022A720-513D-48CE-8410-644349931881"
GROUP = "group.com.example.cranefixture"


def plist(data: dict) -> bytes:
    return plistlib.dumps(data, fmt=plistlib.FMT_BINARY)


def info(app: str = APP, cid: str = CID, **changes) -> dict:
    data = {
        "applicationIdentifier": app,
        "containerIdentifier": cid,
        "containerName": "Disposable test container",
        "originalPaths": {
            app: "/private/var/mobile/Containers/Data/Application/TEST-UUID",
            GROUP: "/private/var/mobile/Containers/Shared/AppGroup/TEST-GROUP",
        },
        "deviceIdentifierForVendor": "45BB3666-477B-44DC-81A8-271D2E071EE9",
    }
    data.update(changes)
    return data


def make_zip(entries: list[tuple[str, bytes | zipfile.ZipInfo]],
             compression: int = zipfile.ZIP_DEFLATED) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=compression) as archive:
        for name, payload in entries:
            # Duplicates here are intentional invalid-fixture test cases.
            # Silence only the stdlib's expected duplicate-name warning.
            with warnings.catch_warnings():
                warnings.filterwarnings("ignore", message="Duplicate name:",
                                        category=UserWarning)
                if isinstance(payload, zipfile.ZipInfo):
                    archive.writestr(payload, b"")
                else:
                    archive.writestr(name, payload)
    return buffer.getvalue()


def single_entries(**info_changes) -> list[tuple[str, bytes | zipfile.ZipInfo]]:
    return [
        ("Info.plist", plist(info(**info_changes))),
        ("Metadata.plist", plist({f"{APP}/Library/Preferences/test.plist":
                                   {"NSFilePosixPermissions": 0o600}})),
        (f"{APP}/Library/Preferences/test.plist", b"test value"),
        (f"{GROUP}/Documents/empty-file", b""),
        ("Keychain.plist", b"SECRET_KEYCHAIN_MUST_NEVER_BE_READ"),
    ]


def multi_entries() -> list[tuple[str, bytes | zipfile.ZipInfo]]:
    index = {"containedContainers": [
        {"applicationIdentifier": APP, "containerIdentifier": CID,
         "containerName": "first"},
        {"applicationIdentifier": APP2, "containerIdentifier": CID2,
         "containerName": "second"},
    ]}
    entries = [("Info.plist", plist(index))]
    for app, cid in ((APP, CID), (APP2, CID2)):
        base = f"{app}/{cid}/"
        entries += [
            (base + "Info.plist", plist(info(app=app, cid=cid))),
            (base + f"{app}/Documents/hello.txt", b"hello"),
        ]
    return entries


class InspectorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="crane-inspect-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, entries, extension=".cranect",
              compression=zipfile.ZIP_DEFLATED) -> Path:
        path = self.root / f"fixture{extension}"
        path.write_bytes(make_zip(entries, compression=compression))
        return path

    def invalid(self, entries, extension=".cranect"):
        with self.assertRaises(InvalidArchive):
            inspect_archive(self.write(entries, extension))

    def test_single_schema_is_structural_only_and_read_only(self):
        path = self.write(single_entries())
        original_content = path.read_bytes()
        result = inspect_archive(path)
        self.assertEqual(result["status"], "structural_pass_not_verified")
        self.assertEqual(result["kind"], "single")
        self.assertEqual(result["member_count"], 5)
        self.assertEqual(len(result["containers"]), 1)
        self.assertEqual(result["containers"][0]["application_identifier"], APP)
        self.assertTrue(result["containers"][0]["has_keychain"])
        self.assertTrue(result["containers"][0]["has_metadata"])
        self.assertFalse(result["keychain_contents_read"])
        self.assertFalse(result["payload_crc_verified"])
        self.assertFalse(result["extracted"])
        self.assertNotIn(b"SECRET_KEYCHAIN_MUST_NEVER_BE_READ",
                         json.dumps(result).encode())
        self.assertEqual(original_content, path.read_bytes())
        self.assertEqual([p.name for p in self.root.iterdir()], ["fixture.cranect"])

    def test_multi_schema_and_legacy_paths(self):
        entries = multi_entries()
        self.assertEqual(len(inspect_archive(self.write(entries, ".cranebk"))
                             ["containers"]), 2)
        legacy = info(originalPaths=None, applicationGroups={
            GROUP: "/var/mobile/Containers/Shared/AppGroup/OLDER-GROUP"
        }, originalPath="/var/mobile/Containers/Data/Application/OLDER")
        legacy.pop("originalPaths")
        self.assertEqual(inspect_archive(self.write(
            [("Info.plist", plist(legacy))]))["kind"], "single")

    def test_root_index_must_match_archive_kind(self):
        self.invalid([("Info.plist", plist({"containedContainers": []}))])
        self.invalid(single_entries(), ".cranebk")
        self.invalid([("Info.plist", plist({"containedContainers": []}))],
                     ".cranebk")

    def test_missing_or_mismatched_multi_records(self):
        entries = multi_entries()
        self.invalid(entries[:-1] + [("UNDECLARED/file", b"x")], ".cranebk")
        self.invalid([entry for entry in entries
                      if entry[0] != f"{APP2}/{CID2}/Info.plist"], ".cranebk")
        bad = list(entries)
        bad[1] = (bad[1][0], plist(info(app=APP2, cid=CID)))
        self.invalid(bad, ".cranebk")
        bad = list(entries)
        bad[0] = ("Info.plist", plist({"containedContainers": [
            {"applicationIdentifier": APP, "containerIdentifier": CID},
            {"applicationIdentifier": APP, "containerIdentifier": CID}]}))
        self.invalid(bad, ".cranebk")

    def test_reject_traversal_and_weird_member_names(self):
        for filename in ("../outside", "/absolute/file",
                         r"foo\bar", "a//b", "a/./b", "a/../b",
                         "C:/system", "associated\ncontrol"):
            with self.subTest(filename=filename):
                self.invalid(single_entries() + [(filename, b"payload")])

    def test_reject_symlink_and_special_files(self):
        for mode in (stat.S_IFLNK | 0o777, stat.S_IFCHR | 0o600,
                     stat.S_IFIFO | 0o644):
            with self.subTest(mode=mode):
                link = zipfile.ZipInfo(f"{APP}/Library/evil")
                link.create_system = 3
                link.external_attr = mode << 16
                self.invalid(single_entries() + [(link.filename, link)])

    def test_reject_collisions_and_file_shadowing(self):
        self.invalid(single_entries() + [("Info.plist", plist(info()))])
        self.invalid(single_entries() + [("info.PLIST", b"collision")])
        self.invalid(single_entries() + [(APP, b"file"),
                                         (APP + "/Documents/hi", b"data")])

    def test_reject_unknown_data_root_and_malformed_plists(self):
        self.invalid(single_entries() + [("unknown/file.txt", b"data")])
        self.invalid([("Info.plist", b"not an XML or binary plist")])
        self.invalid([("Info.plist", plist({"applicationIdentifier": APP}))])
        self.invalid(single_entries(originalPaths={APP: "../../etc/passwd"}))
        self.invalid(single_entries(originalPaths={APP: "/safe/../bad"}))
        self.invalid(single_entries(originalPaths={APP: "/safe", "../BAD": "/safe"}))
        self.invalid([e for e in single_entries() if e[0] != "Metadata.plist"]
                     + [("Metadata.plist", b"bad")])
        self.invalid([("Info.plist", plist(info())), ("Metadata.plist",
                        plist({"../outside": {"NSFilePosixPermissions": 7}}))])

    def test_reject_oversized_plist_and_compression_bombs(self):
        entries = single_entries()
        entries[0] = ("Info.plist", os.urandom(2 * 1024 ** 2 + 1))
        self.invalid(entries)
        with self.assertRaises(UnsupportedArchive):
            inspect_archive(self.write(single_entries() + [
                (f"{APP}/Documents/bomb", b"0" * (2 * 1024 ** 2))]))

    def test_encrypted_archive_reports_unsupported_not_valid(self):
        raw = bytearray(make_zip(single_entries()))
        # Set general-purpose bit zero in the local and central Info records.
        local = raw.index(b"PK\x03\x04")
        central = raw.index(b"PK\x01\x02")
        struct.pack_into("<H", raw, local + 6,
                         struct.unpack_from("<H", raw, local + 6)[0] | 1)
        struct.pack_into("<H", raw, central + 8,
                         struct.unpack_from("<H", raw, central + 8)[0] | 1)
        path = self.root / "encrypted.cranect"
        path.write_bytes(raw)
        with self.assertRaisesRegex(UnsupportedArchive, "encrypted ZIP"):
            inspect_archive(path)

    def test_cli_status_codes_and_never_print_keychain(self):
        path = self.write(single_entries())
        cli = Path(__file__).with_name("crane_backup_inspector.py")
        result = subprocess.run([sys.executable, str(cli), str(path)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"],
                         "structural_pass_not_verified")
        self.assertNotIn("SECRET_KEYCHAIN", result.stdout)
        missing = subprocess.run([sys.executable, str(cli),
                                  str(self.root / "none.cranect")],
                                 capture_output=True, text=True, check=False)
        self.assertEqual(missing.returncode, 1)
        self.assertEqual(json.loads(missing.stdout)["status"], "invalid")

    @staticmethod
    def tamper_member(data: bytes, target: str, *, header: bool = False) -> bytes:
        """Mutate one local filename/payload byte without changing ZIP index."""
        raw = bytearray(data)
        with zipfile.ZipFile(io.BytesIO(data), "r") as zf:
            entry = zf.getinfo(target)
            start = entry.header_offset
            name_len, extra_len = struct.unpack_from("<HH", raw, start + 26)
            start += 30
            if header:
                index = start + max(0, name_len - 1)
            else:
                index = start + name_len + extra_len
            raw[index] ^= 1
        return bytes(raw)

    def test_opt_in_stream_crc_for_non_keychain_files(self):
        entries = [part for part in single_entries()
                   if part[0] != "Keychain.plist"]
        path = self.write(entries, compression=zipfile.ZIP_STORED)
        result = inspect_archive(path, verify_payload=True)
        self.assertTrue(result["payload_crc_verified"])
        self.assertTrue(result["non_keychain_payload_crc_verified"])
        self.assertGreater(result["crc_checked_bytes"], 0)
        self.assertFalse(result["keychain_contents_read"])
        self.assertFalse(result["extracted"])

        broken = self.tamper_member(path.read_bytes(),
                                    f"{APP}/Library/Preferences/test.plist")
        path.write_bytes(broken)
        # Structural-only inspection deliberately cannot certify payload CRC.
        self.assertFalse(inspect_archive(path)["payload_crc_verified"])
        with self.assertRaises(InvalidArchive):
            inspect_archive(path, verify_payload=True)

    def test_opt_in_crc_skips_keychain_bytes_and_reports_incomplete(self):
        path = self.write(single_entries(), compression=zipfile.ZIP_STORED)
        path.write_bytes(self.tamper_member(path.read_bytes(), "Keychain.plist"))
        result = inspect_archive(path, verify_payload=True)
        self.assertTrue(result["non_keychain_payload_crc_verified"])
        self.assertFalse(result["payload_crc_verified"])
        self.assertFalse(result["keychain_contents_read"])
        self.assertFalse(result["extracted"])
        self.assertTrue(result["containers"][0]["has_keychain"])

    def test_opt_in_rejects_local_header_filename_mismatch(self):
        path = self.write(single_entries(), compression=zipfile.ZIP_STORED)
        path.write_bytes(self.tamper_member(path.read_bytes(),
            f"{APP}/Library/Preferences/test.plist", header=True))
        self.assertEqual(inspect_archive(path)["status"],
                         "structural_pass_not_verified")
        with self.assertRaises(InvalidArchive):
            inspect_archive(path, verify_payload=True)

    def test_opt_in_crc_budget_is_enforced_before_streaming(self):
        path = self.write(single_entries())
        with mock.patch.object(inspector, "MAX_VERIFY_BYTES", 1):
            with self.assertRaisesRegex(UnsupportedArchive, "CRC inspection budget"):
                inspect_archive(path, verify_payload=True)
        self.assertEqual(inspect_archive(path)["status"],
                         "structural_pass_not_verified")

    def test_cli_opt_in_crc_flag_and_no_file_mutations(self):
        path = self.write(single_entries())
        original_bytes = path.read_bytes()
        cli = Path(__file__).with_name("crane_backup_inspector.py")
        response = subprocess.run([sys.executable, str(cli), str(path),
                                   "--verify-payload"],
                                  capture_output=True, text=True, check=False)
        self.assertEqual(response.returncode, 0, response.stderr)
        parsed = json.loads(response.stdout)
        self.assertTrue(parsed["non_keychain_payload_crc_verified"])
        self.assertFalse(parsed["payload_crc_verified"])
        self.assertNotIn("SECRET_KEYCHAIN_MUST_NEVER_BE_READ", response.stdout)
        self.assertEqual(path.read_bytes(), original_bytes)
        self.assertEqual([p.name for p in self.root.iterdir()], ["fixture.cranect"])

    def test_unknown_extension_and_bad_zip(self):
        with self.assertRaises(InvalidArchive):
            inspect_archive(self.write(single_entries(), ".zip"))
        file = self.root / "corrupt.cranect"
        file.write_bytes(b"not-a-zip")
        with self.assertRaises(InvalidArchive):
            inspect_archive(file)


if __name__ == "__main__":
    unittest.main()
