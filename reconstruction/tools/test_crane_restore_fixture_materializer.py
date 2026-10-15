"""G-11 D4: only disposable, double-marked TEMP fixture file restoration."""
from __future__ import annotations

import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

import crane_backup_fixture_writer as writer
from crane_backup_inspector import InvalidArchive
from crane_restore_fixture_materializer import (
    LAB, LAB_MARKER, LAB_MARKER_VALUE, FAILPOINTS, InjectedFault,
    MaterializeError, materialize_fixture,
)

APP = "com.example.crane-d4"
APP2 = "org.example.crane-d4"
GROUP = "group.com.example.crane-d4"
SRC = "A8C9771A-CA80-4054-8CF5-44EAE9F6B120"
SRC2 = "BAD7F088-CA80-4054-8CF5-44EAE9F6B121"
DST = "D90CB207-CA80-4054-8CF5-44EAE9F6B122"
DST2 = "AB8324BB-CA80-4054-8CF5-44EAE9F6B123"
SECRET = "PRIVATE_DO_NOT_DISCLOSE"


def container(app: str, cid: str, folder: str) -> dict:
    return {
        "applicationIdentifier": app,
        "containerIdentifier": cid,
        "containerName": SECRET,
        "originalPaths": {
            app: "/private/var/mobile/data/" + SECRET,
            GROUP: "/private/var/mobile/shared/" + SECRET,
        },
        "sourceDirectories": {
            app: folder + "/app",
            GROUP: folder + "/group",
        },
    }


def target(app: str, cid: str, **overrides) -> dict:
    item = {
        "applicationIdentifier": app,
        "containerIdentifier": cid,
        "defaultAssociatedIdentifiers": [app, GROUP],
        "targetAssociatedIdentifiers": [app, GROUP],
        "active": False,
        "existingData": False,
    }
    item.update(overrides)
    return item


def mapping(app: str, source: str, dest: str) -> dict:
    return {
        "sourceApplicationIdentifier": app,
        "sourceContainerIdentifier": source,
        "targetApplicationIdentifier": app,
        "targetContainerIdentifier": dest,
    }


class MaterializerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="crane-d4-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / writer.MARKER).write_bytes(writer.MARKER_CONTENT)
        (self.root / "output").mkdir()
        self.lab = self.root / LAB
        self.lab.mkdir()
        (self.lab / LAB_MARKER).write_bytes(LAB_MARKER_VALUE)
        (self.lab / "staging").mkdir()
        (self.lab / "published").mkdir()

        for folder in ("one", "two"):
            app = self.root / folder / "app"
            group = self.root / folder / "group"
            (app / "Library" / "Preferences").mkdir(parents=True)
            (app / "EmptyFolder").mkdir()
            group.mkdir(parents=True)
            (app / "Library" / "Preferences" / "settings.plist").write_bytes(
                b"SYNTHETIC_APP_CONTENT")
            (group / "empty.txt").write_bytes(b"")
        self.archive = self.make("sample.cranect", [container(APP, SRC, "one")])
        self.inventory = self.root / "inventory.json"
        self.set_inventory([target(APP, DST)], [mapping(APP, SRC, DST)])

    def make(self, filename: str, records: list[dict]) -> Path:
        (self.root / "manifest.json").write_text(
            json.dumps({"containers": records}), encoding="utf-8")
        writer.write_fixture(
            self.root, manifest_name="manifest.json", output_name=filename)
        path = self.root / "output" / filename
        # Host Windows dirs may default to 0o777. Normalize ONLY synthetic
        # Metadata.plist permissions to 0o700 so D3 sees no privileged modes.
        with zipfile.ZipFile(path, "r") as zf:
            entries = [(entry, zf.read(entry)) for entry in zf.infolist()]
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            for item, data in entries:
                updated = zipfile.ZipInfo(item.filename)
                updated.create_system = item.create_system
                updated.external_attr = item.external_attr
                updated.compress_type = item.compress_type
                if item.filename.endswith("Metadata.plist"):
                    value = plistlib.loads(data)
                    for attrs in value.values():
                        attrs["NSFilePosixPermissions"] = 0o700
                    data = plistlib.dumps(value, fmt=plistlib.FMT_BINARY)
                archive.writestr(updated, data)
        path.write_bytes(buffer.getvalue())
        return path

    def set_inventory(self, targets: list[dict], mappings: list[dict]):
        self.inventory.write_text(json.dumps({
            "targets": targets, "mappings": mappings, "freeBytes": 1000000000,
        }), encoding="utf-8")

    def multi(self):
        self.archive = self.make("multi.cranebk", [
            container(APP, SRC, "one"), container(APP2, SRC2, "two")
        ])
        self.set_inventory(
            [target(APP, DST), target(APP2, DST2)],
            [mapping(APP, SRC, DST), mapping(APP2, SRC2, DST2)])

    def run_lab(self, fail=None):
        return materialize_fixture(
            self.root, self.archive, self.inventory, inject_failure=fail)

    def published(self) -> Path:
        return self.lab / "published" / "batch"

    def assert_redacted(self, result):
        text = json.dumps(result, sort_keys=True)
        for private in (APP, APP2, SRC, SRC2, DST, DST2, GROUP, SECRET,
                        "settings.plist", "/private/"):
            self.assertNotIn(private, text)
        self.assertFalse(result["restore_executable"])
        self.assertFalse(result["device_data_touched"])
        self.assertFalse(result["keychain_contents_read"])
        self.assertFalse(result["real_rollback_implemented"])

    def test_single_archive_materializes_file_bytes_and_empty_paths(self):
        original_archive = self.archive.read_bytes()
        result = self.run_lab()
        self.assertEqual(result["status"], "fixture_materialized_not_restore")
        self.assertEqual(result["containers"], 1)
        self.assertEqual(result["files"], 2)
        self.assertEqual(result["bytes"], len(b"SYNTHETIC_APP_CONTENT"))
        batch = self.published()
        files = list(batch.rglob("settings.plist"))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].read_bytes(), b"SYNTHETIC_APP_CONTENT")
        self.assertEqual(len(list(batch.rglob("EmptyFolder"))), 1)
        empty = list(batch.rglob("empty.txt"))
        self.assertEqual(len(empty), 1)
        self.assertEqual(empty[0].read_bytes(), b"")
        self.assertEqual(self.archive.read_bytes(), original_archive)
        self.assertEqual(list((self.lab / "staging").iterdir()), [])
        self.assert_redacted(result)

    def test_multi_atomic_single_directory_publish(self):
        self.multi()
        result = self.run_lab()
        self.assertEqual(result["containers"], 2)
        self.assertEqual(result["files"], 4)
        batch = self.published()
        self.assertTrue((batch / "container-1").is_dir())
        self.assertTrue((batch / "container-2").is_dir())
        self.assertEqual(len(list(batch.rglob("settings.plist"))), 2)
        self.assert_redacted(result)

    def test_multi_subset_only_materializes_selected(self):
        self.multi()
        self.set_inventory([target(APP, DST)], [mapping(APP, SRC, DST)])
        result = self.run_lab()
        self.assertEqual(result["containers"], 1)
        self.assertEqual(result["files"], 2)
        self.assertFalse((self.published() / "container-2").exists())

    def test_injected_failure_rolls_back_staged_files(self):
        self.multi()
        for failpoint in FAILPOINTS:
            with self.subTest(point=failpoint):
                try:
                    self.run_lab(failpoint)
                    self.fail("injected failure was ignored")
                except InjectedFault:
                    pass
                self.assertEqual(list((self.lab / "staging").iterdir()), [])
                self.assertEqual(list((self.lab / "published").iterdir()), [])

    def test_existing_published_directory_refused_no_overwrite(self):
        self.published().mkdir()
        (self.published() / "KEEP.txt").write_bytes(b"DO_NOT_TOUCH")
        with self.assertRaises(MaterializeError):
            self.run_lab()
        self.assertEqual((self.published() / "KEEP.txt").read_bytes(),
                         b"DO_NOT_TOUCH")
        self.assertEqual(list((self.lab / "staging").iterdir()), [])

    def test_orphan_staging_refused_without_auto_cleanup(self):
        folder = self.lab / "staging" / "batch"
        folder.mkdir()
        (folder / "manual-note").write_text("PRESERVE")
        with self.assertRaises(MaterializeError):
            self.run_lab()
        self.assertEqual((folder / "manual-note").read_text(), "PRESERVE")

    def test_invalid_marker_refused_before_staging(self):
        (self.lab / LAB_MARKER).write_bytes(b"INVALID")
        with self.assertRaises(MaterializeError):
            self.run_lab()
        self.assertEqual(list((self.lab / "staging").iterdir()), [])

    def test_outside_archive_refused(self):
        outside = self.root / "other.cranect"
        outside.write_bytes(self.archive.read_bytes())
        with self.assertRaises(MaterializeError):
            materialize_fixture(self.root, outside, self.inventory)

    def test_inventory_outside_root_refused(self):
        outside = self.root / "output" / "inventory.json"
        outside.write_bytes(self.inventory.read_bytes())
        with self.assertRaises(MaterializeError):
            materialize_fixture(self.root, self.archive, outside)

    def test_active_or_existing_target_blocks_all_writes(self):
        for change in ({"active": True}, {"existingData": True}):
            self.set_inventory([target(APP, DST, **change)],
                               [mapping(APP, SRC, DST)])
            with self.subTest(change=change):
                with self.assertRaises(MaterializeError):
                    self.run_lab()
                self.assertEqual(list((self.lab / "staging").iterdir()), [])
        self.assertEqual(list((self.lab / "published").iterdir()), [])

    def test_keychain_archive_never_materialized(self):
        contents = []
        with zipfile.ZipFile(self.archive) as source:
            contents = [(m, source.read(m)) for m in source.infolist()]
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as dest:
            for item, contents_bytes in contents:
                info = zipfile.ZipInfo(item.filename)
                info.compress_type = item.compress_type
                info.external_attr = item.external_attr
                info.create_system = item.create_system
                dest.writestr(info, contents_bytes)
            dest.writestr("Keychain.plist", SECRET)
        self.archive.write_bytes(buffer.getvalue())
        with self.assertRaises(MaterializeError):
            self.run_lab()
        self.assertFalse(self.published().exists())

    def test_zip_bad_traversal_refused(self):
        original = self.archive.read_bytes()
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as zf:
            with zipfile.ZipFile(io.BytesIO(original), "r") as prev:
                for member in prev.infolist():
                    zf.writestr(member, prev.read(member))
            zf.writestr("../OUTSIDE.txt", b"ATTACK")
        self.archive.write_bytes(buffer.getvalue())
        with self.assertRaises(InvalidArchive):
            self.run_lab()
        self.assertFalse(self.published().exists())

    def test_disallowed_platform_filename_refused_after_preflight(self):
        filename = f"{APP}/CON"
        # Name 'CON' is associated root FILE, so inspector rejects. Instead
        # use a nested Windows device basename in a valid associated root.
        filename = f"{APP}/Library/NUL.txt"
        with zipfile.ZipFile(self.archive, "r") as zf:
            members = [(item, zf.read(item)) for item in zf.infolist()]
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            for item, value in members:
                zf.writestr(item, value)
            zf.writestr(filename, b"TEST")
        self.archive.write_bytes(buf.getvalue())
        with self.assertRaises(MaterializeError):
            self.run_lab()
        self.assertFalse(self.published().exists())
        self.assertEqual(list((self.lab / "staging").iterdir()), [])

    def test_cli_fault_status_and_privacy(self):
        cli = Path(__file__).with_name("crane_restore_fixture_materializer.py")
        cmd = [sys.executable, str(cli), "--fixture-root", str(self.root),
               "--archive", str(self.archive),
               "--inventory", str(self.inventory)]
        failure = subprocess.run(
            cmd + ["--inject-failure", "after_first_file"],
            capture_output=True, text=True)
        self.assertEqual(failure.returncode, 3, failure.stderr)
        self.assertEqual(json.loads(failure.stdout)["status"],
                         "fixture_stage_rolled_back")
        self.assertNotIn(SECRET, failure.stdout + failure.stderr)
        self.assertEqual(list((self.lab / "staging").iterdir()), [])
        success = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(json.loads(success.stdout)["status"],
                         "fixture_materialized_not_restore")
        self.assertNotIn(APP, success.stdout)
        self.assertTrue(self.published().is_dir())

    def test_no_preexisting_source_mutation(self):
        before = (self.archive.read_bytes(), self.inventory.read_bytes(),
                  (self.root / "one/app/Library/Preferences/settings.plist").read_bytes())
        self.run_lab()
        after = (self.archive.read_bytes(), self.inventory.read_bytes(),
                 (self.root / "one/app/Library/Preferences/settings.plist").read_bytes())
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
