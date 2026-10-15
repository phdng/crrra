"""G-11 experimental OFFLINE writer: disposable fixture-only round-trip tests."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

import crane_backup_fixture_writer as writer
from crane_backup_inspector import inspect_archive

APP = "com.example.cranefixture"
OTHER_APP = "org.example.cranefixture"
CID = "F3E0123D-6B73-46BD-95E7-161BE46EAB80"
CID2 = "CE21952E-63A3-4967-AC21-1DB458FD671C"
GROUP = "group.com.example.cranefixture"


def container(app: str, cid: str, parent: str) -> dict:
    return {
        "applicationIdentifier": app, "containerIdentifier": cid,
        "containerName": "Disposable Fixture",
        "originalPaths": {
            app: "/private/var/mobile/Containers/Data/Application/TEST",
            GROUP: "/private/var/mobile/Containers/Shared/AppGroup/TEST",
        },
        "sourceDirectories": {
            app: parent + "/app",
            GROUP: parent + "/group",
        },
    }


class WriterTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="crane-b-writer-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.output = self.root / "output"
        self.output.mkdir()
        (self.root / writer.MARKER).write_bytes(writer.MARKER_CONTENT)
        self.populate("one")
        self.populate("two")
        self.rows = [container(APP, CID, "one")]

    def populate(self, parent: str):
        app = self.root / parent / "app"
        group = self.root / parent / "group"
        (app / "Library" / "Preferences").mkdir(parents=True)
        (app / "EmptyDir").mkdir()
        group.mkdir(parents=True)
        (app / "Library" / "Preferences" / "settings.plist").write_bytes(
            plistlib.dumps({"fixtureFlag": True}, fmt=plistlib.FMT_BINARY))
        (app / "Library" / "Preferences" / "zero.txt").write_bytes(b"")
        (group / "group.txt").write_bytes(b"NOT_PRIVATE_FIXTURE")
        (group / "Nested").mkdir()
        (group / "Nested" / "member.bin").write_bytes(bytes(range(256)))

    def manifest(self, rows: list[dict] | None = None):
        (self.root / "manifest.json").write_text(json.dumps({
            "containers": self.rows if rows is None else rows
        }), encoding="utf-8")

    def write(self, file: str = "fixture.cranect") -> Path:
        return_path = self.output / file
        writer.write_fixture(self.root, manifest_name="manifest.json",
                             output_name=file)
        return return_path

    def test_single_binary_manifest_and_roundtrip_crc(self):
        self.manifest()
        destination = self.write()
        self.assertTrue(destination.is_file())
        validation = inspect_archive(destination, verify_payload=True)
        self.assertEqual(validation["kind"], "single")
        self.assertTrue(validation["payload_crc_verified"])
        self.assertFalse(validation["containers"][0]["has_keychain"])
        self.assertTrue(validation["containers"][0]["has_metadata"])
        with zipfile.ZipFile(destination) as zf:
            metadata = plistlib.loads(zf.read("Info.plist"))
            self.assertEqual(metadata["originalPaths"][APP],
                             self.rows[0]["originalPaths"][APP])
            self.assertEqual(metadata["applicationIdentifier"], APP)
            self.assertTrue(zf.read("Info.plist").startswith(b"bplist"))
            self.assertEqual(zf.read(f"{GROUP}/group.txt"),
                             b"NOT_PRIVATE_FIXTURE")
            self.assertEqual(zf.read(f"{APP}/Library/Preferences/zero.txt"), b"")
            self.assertIn(f"{APP}/EmptyDir/", zf.namelist())
            self.assertIn(f"{GROUP}/Nested/member.bin", zf.namelist())
            attrs = plistlib.loads(zf.read("Metadata.plist"))
            self.assertIn(f"{APP}/Library/Preferences/settings.plist", attrs)
            target_attributes = attrs[f"{APP}/Library/Preferences/settings.plist"]
            self.assertIn("NSFilePosixPermissions", target_attributes)
            self.assertIn("NSFileModificationDate", target_attributes)
            self.assertIsNone(target_attributes["NSFileModificationDate"].tzinfo)
            self.assertNotIn("NSFileSize", target_attributes)
            self.assertNotIn("NSFileReferenceCount", target_attributes)
            self.assertEqual(target_attributes["NSFilePosixPermissions"],
                             stat.S_IMODE((self.root / "one" / "app" / "Library" /
                                  "Preferences" / "settings.plist").stat().st_mode))

    def test_multi_root_index_and_roundtrip(self):
        second = container(OTHER_APP, CID2, "two")
        self.manifest(self.rows + [second])
        path = self.write("fixture.cranebk")
        checked = inspect_archive(path, verify_payload=True)
        self.assertEqual(checked["kind"], "multi")
        self.assertEqual(len(checked["containers"]), 2)
        self.assertTrue(checked["payload_crc_verified"])
        with zipfile.ZipFile(path) as zf:
            index = plistlib.loads(zf.read("Info.plist"))
            self.assertEqual(len(index["containedContainers"]), 2)
            for row in self.rows + [second]:
                prefix = row["applicationIdentifier"] + "/" + row["containerIdentifier"] + "/"
                info = plistlib.loads(zf.read(prefix + "Info.plist"))
                self.assertEqual(info["containerIdentifier"],
                                 row["containerIdentifier"])
                self.assertIn(prefix + "Metadata.plist", zf.namelist())

    def test_reject_unmarked_root_without_output(self):
        self.manifest()
        (self.root / writer.MARKER).write_bytes(b"WRONG_MARKER")
        with self.assertRaises(writer.FixtureError):
            self.write()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_reject_existing_file_preserving_exact_bytes(self):
        self.manifest()
        existing = self.output / "fixture.cranect"
        existing.write_bytes(b"KEEP ORIGINAL")
        with self.assertRaises(writer.FixtureError):
            self.write()
        self.assertEqual(existing.read_bytes(), b"KEEP ORIGINAL")
        self.assertEqual([p.name for p in self.output.iterdir()],
                         ["fixture.cranect"])

    def test_reject_escape_and_untrusted_manifest_options(self):
        self.manifest()
        for bad in ("../out", "/absolute/out", "one/../two",
                    "output/fixture", "one//app", r"one\app"):
            with self.subTest(path=bad):
                record = container(APP, CID, "one")
                record["sourceDirectories"][APP] = bad
                self.manifest([record])
                with self.assertRaises((writer.FixtureError, OSError)):
                    self.write()
        record = container(APP, CID, "one")
        record["includeKeychain"] = True
        self.manifest([record])
        with self.assertRaises(writer.FixtureError):
            self.write()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_reject_source_symlink(self):
        if not hasattr(os, "symlink"):
            self.skipTest("symlink API absent")
        root = self.root / "one"
        link = root / "app" / "escape"
        try:
            link.symlink_to(self.root / "two" / "app", target_is_directory=True)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlink not permitted: {exc}")
        self.manifest()
        with self.assertRaises(writer.FixtureError):
            self.write()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_reject_duplicate_id_or_case_collision(self):
        self.manifest(self.rows + self.rows)
        with self.assertRaises(writer.FixtureError):
            self.write("fixture.cranebk")
        duplicate = container(APP, CID, "one")
        duplicate["sourceDirectories"]["GROUP.com.example.cranefixture"] = (
            duplicate["sourceDirectories"][GROUP])
        duplicate["originalPaths"]["GROUP.com.example.cranefixture"] = (
            duplicate["originalPaths"][GROUP])
        self.manifest([duplicate])
        with self.assertRaises(writer.FixtureError):
            self.write()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_reject_reserved_associated_id_and_unsafe_output(self):
        row = container(APP, CID, "one")
        row["originalPaths"]["Info.plist"] = "/private/var/mobile/TEST"
        row["sourceDirectories"]["Info.plist"] = "one/group"
        self.manifest([row])
        with self.assertRaisesRegex(writer.FixtureError, "reserved"):
            self.write()
        self.manifest()
        for filename in ("bad\\\\name.cranect", "bad:name.cranect",
                         "bad\\nname.cranect", ".hidden.cranect"):
            with self.subTest(filename=filename):
                with self.assertRaises(writer.FixtureError):
                    self.write(filename)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_reject_single_filename_for_multi_manifest(self):
        self.manifest(self.rows + [container(OTHER_APP, CID2, "two")])
        with self.assertRaises(writer.FixtureError):
            self.write()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_reject_binary_data_above_limit_and_leave_no_staging(self):
        self.manifest()
        path = self.root / "one" / "app" / "bigfile.bin"
        with path.open("wb") as handle:
            handle.truncate(writer.MAX_FILE_SIZE + 1)
        with self.assertRaises(writer.FixtureError):
            self.write()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_fail_before_publish_and_cleanup_unique_staging(self):
        self.manifest()
        with mock.patch.object(writer, "inspect_archive",
                               side_effect=writer.InvalidArchive("synthetic corruption")):
            with self.assertRaises(writer.FixtureError):
                self.write()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_cli_json_and_refusal_of_unauthorized_output(self):
        self.manifest()
        cli = Path(writer.__file__)
        result = subprocess.run([sys.executable, str(cli),
                                 "--fixture-root", str(self.root),
                                 "--output", "fixture.cranect"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"],
                         "synthetic_fixture_only_not_original_compatible")
        self.assertNotIn("NOT_PRIVATE_FIXTURE", result.stdout)
        fail = subprocess.run([sys.executable, str(cli),
                               "--fixture-root", str(self.root),
                               "--output", "../overwrite.cranect"],
                              capture_output=True, text=True)
        self.assertEqual(fail.returncode, 1)
        self.assertEqual(json.loads(fail.stdout)["status"], "fixture_failed")
        self.assertFalse((self.root / "overwrite.cranect").exists())

    def test_source_tree_is_unchanged_by_writer(self):
        self.manifest()
        before = (self.root / "one" / "group" / "group.txt").read_bytes()
        path = self.write()
        self.assertEqual((self.root / "one" / "group" /
                          "group.txt").read_bytes(), before)
        self.assertTrue(path.is_file())
        self.assertEqual(list(self.output.iterdir()), [path])


if __name__ == "__main__":
    unittest.main()
