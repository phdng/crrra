"""N3 synthetic CRC fixtures: unchanged ZIP headers, changed compressed bytes.

The user-provided original Chrome archive is NEVER read in this test.
Actual Objective-C CRC pass/fail runs in macOS CI via native_backup_crc_smoke.m.
"""
from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
import zipfile
import zlib

import native_backup_survey_fixture as fixtures


class NativeCRCTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="crane-n3-")
        self.addCleanup(temp.cleanup)
        self.paths = fixtures.create(Path(temp.name))
        self.by_name = {path.name: path for path in self.paths}

    def test_crc_corrupted_ordinary_payload_with_intact_zip_headers(self):
        valid = self.by_name["crane-survey-valid.cranect"]
        corrupt = self.by_name["crane-survey-payload-corrupt.cranect"]
        with zipfile.ZipFile(valid) as good, zipfile.ZipFile(corrupt) as bad:
            good_list = good.infolist()
            bad_list = bad.infolist()
            self.assertEqual(len(good_list), len(bad_list))
            self.assertEqual([(x.filename, x.CRC, x.compress_size, x.file_size,
                               x.flag_bits, x.header_offset) for x in good_list],
                             [(x.filename, x.CRC, x.compress_size, x.file_size,
                               x.flag_bits, x.header_offset) for x in bad_list])
            with self.assertRaises((zipfile.BadZipFile, zlib.error)):
                bad.read("com.example.crane.native/one.txt")

    def test_tampered_keychain_compressed_bytes_are_not_read_by_n3(self):
        intact = self.by_name["crane-survey-keychain-shape.cranect"]
        tampered = self.by_name["crane-survey-keychain-corrupt.cranect"]
        with zipfile.ZipFile(intact) as good, zipfile.ZipFile(tampered) as bad:
            self.assertEqual([x.filename for x in good.infolist()],
                             [x.filename for x in bad.infolist()])
            self.assertEqual(good.read("com.example.crane.native/one.txt"),
                             bad.read("com.example.crane.native/one.txt"))
            with self.assertRaises((zipfile.BadZipFile, zlib.error)):
                bad.read("Keychain.plist")

    def test_large_incompressible_like_dummy_payload_crosses_buffer(self):
        with zipfile.ZipFile(
                self.by_name["crane-survey-large-payload.cranect"]) as zf:
            member = zf.getinfo("com.example.crane.native/one.txt")
            self.assertGreater(member.file_size, 32768)
            self.assertEqual(zf.read(member), bytes(range(256)) * 420)

    def test_zip_stored_nonempty_dummy_file(self):
        with zipfile.ZipFile(
                self.by_name["crane-survey-stored-payload.cranect"]) as zf:
            member = zf.getinfo("com.example.crane.native/one.txt")
            self.assertEqual(member.compress_type, zipfile.ZIP_STORED)
            self.assertEqual(zf.read(member), b"FAKE_NOT_PRIVATE")

    def test_native_api_is_explicit_and_keeps_header_only_default(self):
        root = Path(__file__).resolve().parents[2] / "reconstruction/sources/prefs"
        hdr = (root / "CRBackupArchiveSurvey.h").read_text(encoding="utf8")
        src = (root / "CRBackupArchiveSurvey.m").read_text(encoding="utf8")
        self.assertIn("verifyNonKeychainPayloadAtPath:", hdr)
        self.assertIn("SSurvey(fd, NO)", src)
        self.assertIn("SSurvey(fd, YES)", src)
        self.assertIn("if (verifyCRC && !isKeychain)", src)
        self.assertIn("SVerifyEntryCRC(fd, body, comp, uncomp, method", src)
        self.assertNotIn("SecItemCopyMatching", src)


if __name__ == "__main__":
    unittest.main()
