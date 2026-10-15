"""G-11 C4: opt-in synthetic original 8-field metadata SHAPE, never iOS identity.

The fixture writer is restricted to disposable, double-explicitly controlled
test sources. We never copy metadata or Chrome files from the real reference.
"""
from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import unittest
import zipfile

import crane_backup_fixture_writer as writer
from crane_backup_inspector import inspect_archive
from crane_backup_metadata import (
    ORIGINAL_SAMPLE_EIGHT_FIELDS,
    original_sample_shape_synthetic_attributes,
)
from crane_original_archive_audit import audit_original
import test_crane_backup_fixture_writer as fixture_test
from test_crane_original_archive_audit import ORIGINAL_FIXTURE


class OriginalMetadataShapeTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixture_test.WriterTest(
            "test_single_binary_manifest_and_roundtrip_crc")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.manifest()

    def create(self, name: str = "eight.cranect") -> Path:
        result = writer.write_fixture(
            self.fixture.root, manifest_name="manifest.json",
            output_name=name, metadata_profile="synthetic-original-eight-field")
        self.assertEqual(result["metadata_profile"],
                         "synthetic-original-eight-field")
        self.assertIs(result["original_compatibility_proven"], False)
        return self.fixture.output / name

    def check_eight_records(self, archive: Path):
        with zipfile.ZipFile(archive) as zf:
            metadata = plistlib.loads(zf.read("Metadata.plist"))
            app = plistlib.loads(zf.read("Info.plist"))
            self.assertNotIn("Keychain.plist", zf.namelist())
            self.assertNotIn("syntheticProfile", app)  # original Info schema kept
            directories = {e.filename.rstrip("/") for e in zf.infolist()
                           if e.is_dir()}
            data_files = {e.filename for e in zf.infolist()
                          if not e.is_dir() and e.filename not in
                          ("Info.plist", "Metadata.plist")}
            self.assertEqual(set(metadata), directories | data_files)
            for attributes in metadata.values():
                self.assertEqual(set(attributes), ORIGINAL_SAMPLE_EIGHT_FIELDS)
                self.assertEqual(attributes["NSFileCreationDate"],
                                 datetime(2001, 1, 1))
                self.assertEqual(attributes["NSFileModificationDate"],
                                 datetime(2001, 1, 1))
                self.assertIs(type(attributes["NSFileExtensionHidden"]), bool)
                self.assertIs(type(attributes["NSFileOwnerAccountID"]), int)
                self.assertIs(type(attributes["NSFileGroupOwnerAccountID"]), int)
                self.assertIs(type(attributes["NSFileOwnerAccountName"]), str)
                self.assertIs(type(attributes["NSFileGroupOwnerAccountName"]), str)
                self.assertIs(type(attributes["NSFilePosixPermissions"]), int)
                self.assertIn("NOT-IOS", attributes["NSFileOwnerAccountName"])
                self.assertIn("NOT-IOS", attributes["NSFileGroupOwnerAccountName"])
        inspected = inspect_archive(archive, verify_payload=True)
        self.assertTrue(inspected["payload_crc_verified"])
        return metadata

    def test_source_accurate_eight_key_set_is_explicit(self):
        expected = {
            "NSFileCreationDate", "NSFileModificationDate",
            "NSFileExtensionHidden", "NSFileOwnerAccountID",
            "NSFileOwnerAccountName", "NSFileGroupOwnerAccountID",
            "NSFileGroupOwnerAccountName", "NSFilePosixPermissions",
        }
        self.assertEqual(ORIGINAL_SAMPLE_EIGHT_FIELDS, expected)

    def test_all_synthetic_file_and_directory_rows_match_eight_field_schema(self):
        self.check_eight_records(self.create())

    def test_synthetic_ownership_never_uses_host_uid_gid(self):
        class MockStat:
            st_mode = 0o100640
            st_uid = 0
            st_gid = 0
            st_mtime = 1755555555
            st_birthtime = 1766666666

        attributes = original_sample_shape_synthetic_attributes(MockStat())
        self.assertEqual(attributes["NSFileOwnerAccountID"], 900001)
        self.assertEqual(attributes["NSFileGroupOwnerAccountID"], 900002)
        self.assertNotEqual(attributes["NSFileOwnerAccountID"], MockStat.st_uid)
        self.assertNotEqual(attributes["NSFileGroupOwnerAccountID"], MockStat.st_gid)
        self.assertEqual(attributes["NSFilePosixPermissions"], 0o640)
        self.assertEqual(attributes["NSFileCreationDate"], datetime(2001, 1, 1))
        self.assertEqual(attributes["NSFileModificationDate"], datetime(2001, 1, 1))

    def test_metadata_binary_plist_deterministic_for_same_fixture(self):
        first = self.create("first.cranect")
        second = self.create("second.cranect")
        with zipfile.ZipFile(first) as left, zipfile.ZipFile(second) as right:
            self.assertEqual(left.read("Metadata.plist"), right.read("Metadata.plist"))

    def test_multi_synthetic_profile_applied_to_all_container_records(self):
        self.fixture.manifest(self.fixture.rows + [
            fixture_test.container(fixture_test.OTHER_APP,
                                   fixture_test.CID2, "two")
        ])
        archive = self.create("pair.cranebk")
        with zipfile.ZipFile(archive) as zf:
            for row in (self.fixture.rows[0], fixture_test.container(
                    fixture_test.OTHER_APP, fixture_test.CID2, "two")):
                prefix = (row["applicationIdentifier"] + "/" +
                          row["containerIdentifier"] + "/")
                metadata = plistlib.loads(zf.read(prefix + "Metadata.plist"))
                self.assertTrue(metadata)
                for attrs in metadata.values():
                    self.assertEqual(set(attrs), ORIGINAL_SAMPLE_EIGHT_FIELDS)
        verified = inspect_archive(archive, verify_payload=True)
        self.assertEqual(len(verified["containers"]), 2)
        self.assertTrue(verified["payload_crc_verified"])

    def test_default_mode_is_host_stat_and_does_not_fake_account_names(self):
        self.fixture.write("default.cranect")
        with zipfile.ZipFile(self.fixture.output / "default.cranect") as zf:
            metadata = plistlib.loads(zf.read("Metadata.plist"))
            for values in metadata.values():
                self.assertNotIn("NSFileOwnerAccountName", values)
                self.assertNotIn("NSFileGroupOwnerAccountName", values)
                self.assertNotIn("NSFileExtensionHidden", values)

    def test_reject_unrecognized_profile_before_output(self):
        with self.assertRaises(writer.FixtureError):
            writer.write_fixture(
                self.fixture.root, manifest_name="manifest.json",
                output_name="unknown.cranect", metadata_profile="ios-production")
        self.assertFalse((self.fixture.output / "unknown.cranect").exists())

    def test_fixture_marker_remains_mandatory_in_synthetic_mode(self):
        (self.fixture.root / writer.MARKER).write_bytes(b"wrong")
        with self.assertRaises(writer.FixtureError):
            self.create()
        self.assertFalse((self.fixture.output / "eight.cranect").exists())

    def test_cannot_overwrite_existing_output(self):
        original = self.create()
        before = original.read_bytes()
        with self.assertRaises(writer.FixtureError):
            self.create()
        self.assertEqual(original.read_bytes(), before)

    def test_cli_requires_opt_in_and_redacts_fake_account_values(self):
        cli = Path(writer.__file__)
        result = subprocess.run(
            [sys.executable, str(cli),
             "--fixture-root", str(self.fixture.root),
             "--output", "cli.cranect",
             "--metadata-profile", "synthetic-original-eight-field"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["metadata_profile"],
                         "synthetic-original-eight-field")
        self.assertIs(payload["original_compatibility_proven"], False)
        self.assertNotIn("NOT-IOS", result.stdout)
        self.check_eight_records(self.fixture.output / "cli.cranect")

    @unittest.skipUnless(ORIGINAL_FIXTURE.is_file(),
                         "original backup stays local; CI synthetic tests only")
    def test_original_chrome_eight_field_presence_and_types_match_fixture_shape(self):
        real = audit_original(ORIGINAL_FIXTURE, verify_payload=False)
        self.assertEqual(real["inspector_status"], "accepted")
        self.assertEqual(real["container_count"], 1)
        observed = real["metadata_observations"][0]
        self.assertEqual(set(observed["attribute_presence_counts"]),
                         ORIGINAL_SAMPLE_EIGHT_FIELDS)
        for count in observed["attribute_presence_counts"].values():
            self.assertEqual(count, observed["records"])
        our_metadata = self.check_eight_records(self.create())
        self.assertTrue(our_metadata)
        self.assertEqual({key: (
            "datetime" if isinstance(value, datetime)
            else "bool" if type(value) is bool
            else "integer" if type(value) is int
            else "string" if isinstance(value, str)
            else "other") for key, value in next(iter(our_metadata.values())).items()},
            {key: next(iter(kinds))
             for key, kinds in observed["attribute_value_types"].items()})
        # We compare only the 8-field metadata SHAPE and value types,
        # never the original Chrome values, IDs, content or private paths.


if __name__ == "__main__":
    unittest.main()
