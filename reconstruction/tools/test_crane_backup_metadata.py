"""G-11 exact original writable-key filter and synthetic stat projection tests."""
from __future__ import annotations

from datetime import datetime
import plistlib
import stat
from types import SimpleNamespace
import unittest

from crane_backup_metadata import (
    WRITABLE_FILE_ATTRIBUTES,
    attributes_available_from_stat,
    filter_writable_file_attributes,
)

EXPECTED_KEYS = {
    "NSFileBusy",
    "NSFileCreationDate",
    "NSFileExtensionHidden",
    "NSFileGroupOwnerAccountID",
    "NSFileGroupOwnerAccountName",
    "NSFileHFSCreatorCode",
    "NSFileHFSTypeCode",
    "NSFileImmutable",
    "NSFileModificationDate",
    "NSFileOwnerAccountID",
    "NSFileOwnerAccountName",
    "NSFilePosixPermissions",
}


def synthetic_stat(*, birth=None, owner=501, group=20):
    values = {
        "st_mode": stat.S_IFREG | 0o640,
        "st_mtime": 1609459200,
        "st_ctime": 1700000000,
        "st_uid": owner,
        "st_gid": group,
    }
    if birth is not None:
        values["st_birthtime"] = birth
    return SimpleNamespace(**values)


class BackupMetadataTest(unittest.TestCase):
    def test_native_allowlist_is_exactly_twelve_and_immutable(self):
        self.assertIsInstance(WRITABLE_FILE_ATTRIBUTES, frozenset)
        self.assertEqual(WRITABLE_FILE_ATTRIBUTES, EXPECTED_KEYS)
        self.assertEqual(len(WRITABLE_FILE_ATTRIBUTES), 12)

    def test_native_filter_removes_unwritable_fields_without_mutation(self):
        untrusted = {
            "NSFilePosixPermissions": 0o600,
            "NSFileSize": 1_000_000,
            "NSFileReferenceCount": 40,
            "CustomSecretCredential": "MUST_NOT_LEAK",
            "NSFileModificationDate": datetime(2024, 1, 1),
        }
        result = filter_writable_file_attributes(untrusted)
        self.assertEqual(set(result), {
            "NSFilePosixPermissions", "NSFileModificationDate"})
        self.assertEqual(len(untrusted), 5)
        self.assertNotIn("CustomSecretCredential", str(result))

    def test_native_filter_retains_each_allowed_value(self):
        sample = {key: True for key in EXPECTED_KEYS}
        self.assertEqual(filter_writable_file_attributes(sample), sample)

    def test_stat_projection_uses_utc_naive_datetime(self):
        result = attributes_available_from_stat(synthetic_stat())
        self.assertEqual(result["NSFilePosixPermissions"], 0o640)
        self.assertEqual(result["NSFileOwnerAccountID"], 501)
        self.assertEqual(result["NSFileGroupOwnerAccountID"], 20)
        self.assertEqual(result["NSFileModificationDate"],
                         datetime(2021, 1, 1, 0, 0, 0))
        self.assertIsNone(result["NSFileModificationDate"].tzinfo)
        self.assertNotIn("NSFileCreationDate", result)
        self.assertEqual(set(result) - EXPECTED_KEYS, set())

    def test_birthtime_only_not_change_time(self):
        result = attributes_available_from_stat(synthetic_stat(
            birth=1546300800))
        self.assertEqual(result["NSFileCreationDate"],
                         datetime(2019, 1, 1))
        self.assertNotEqual(result["NSFileCreationDate"],
                            datetime.fromtimestamp(1700000000))

    def test_no_invented_unsupported_platform_fields(self):
        values = attributes_available_from_stat(
            synthetic_stat(owner=None, group=None))
        self.assertNotIn("NSFileOwnerAccountID", values)
        self.assertNotIn("NSFileGroupOwnerAccountID", values)
        for key in ("NSFileBusy", "NSFileExtensionHidden", "NSFileImmutable",
                    "NSFileHFSCreatorCode", "NSFileHFSTypeCode",
                    "NSFileOwnerAccountName", "NSFileGroupOwnerAccountName"):
            self.assertNotIn(key, values)

    def test_binary_plist_dates_roundtrip(self):
        projection = attributes_available_from_stat(synthetic_stat(
            birth=1546300800))
        raw = plistlib.dumps(projection, fmt=plistlib.FMT_BINARY)
        self.assertTrue(raw.startswith(b"bplist00"))
        decoded = plistlib.loads(raw)
        self.assertEqual(decoded, projection)

    def test_date_not_representable_is_omitted_not_fabricated(self):
        sample = synthetic_stat(birth=10**100)
        sample.st_mtime = 10**100
        result = attributes_available_from_stat(sample)
        self.assertNotIn("NSFileCreationDate", result)
        self.assertNotIn("NSFileModificationDate", result)
        self.assertIn("NSFilePosixPermissions", result)


if __name__ == "__main__":
    unittest.main()
