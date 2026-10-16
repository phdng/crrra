"""G-11 N1: disposable-only ZIP central/local structural fixtures.

The real native Objective-C survey is exercised on macOS CI; these Python
tests validate the input corpus and the native source safety contract.
"""
from __future__ import annotations
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

import native_backup_survey_fixture as survey
from test_crane_original_archive_audit import ORIGINAL_FIXTURE


class NativeSurveyFixtureTest(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(prefix="crane-n1-survey-")
        self.addCleanup(t.cleanup)
        self.paths = survey.create(Path(t.name))

    def test_valid_single_has_info_first_metadata_last(self):
        with zipfile.ZipFile(self.paths[0]) as zf:
            self.assertEqual(zf.namelist()[0], "Info.plist")
            self.assertEqual(zf.namelist()[-1], "Metadata.plist")
            self.assertEqual(len(zf.infolist()), 4)
            self.assertEqual(sum(x.is_dir() for x in zf.infolist()), 1)
            self.assertEqual(sum(x.filename == "Keychain.plist"
                                 for x in zf.infolist()), 0)

    def test_all_thirteen_named_vectors_are_temporary(self):
        self.assertEqual(len(self.paths), 13)
        self.assertEqual({p.name for p in self.paths}, {
            "crane-survey-valid.cranect", "crane-survey-traversal.cranect",
            "crane-survey-duplicate.cranect", "crane-survey-symlink.cranect",
            "crane-survey-missing-meta.cranect",
            "crane-survey-local-mismatch.cranect",
            "crane-survey-central-mismatch.cranect",
            "crane-survey-descriptor-mismatch.cranect",
            "crane-survey-keychain-shape.cranect",
            "crane-survey-payload-corrupt.cranect",
            "crane-survey-keychain-corrupt.cranect",
            "crane-survey-large-payload.cranect",
            "crane-survey-stored-payload.cranect",
        })
        self.assertTrue(all(p.stat().st_size < 16384 for p in self.paths))

    def test_path_traversal_is_in_a_zip_central_name(self):
        with zipfile.ZipFile(self.paths[1]) as zf:
            self.assertEqual(sum("/../" in x.filename for x in zf.infolist()), 1)

    def test_duplicate_zip_file_names(self):
        with zipfile.ZipFile(self.paths[2]) as zf:
            members = [x.filename for x in zf.infolist()]
            self.assertEqual(len(set(members)), len(members)-1)

    def test_symlink_external_attributes(self):
        with zipfile.ZipFile(self.paths[3]) as zf:
            self.assertEqual(sum((x.external_attr >> 16) & 0o170000 == 0o120000
                                 for x in zf.infolist()), 1)

    def test_missing_metadata_zip_is_still_parseable(self):
        with zipfile.ZipFile(self.paths[4]) as zf:
            self.assertNotIn("Metadata.plist", zf.namelist())

    def test_local_filename_differs_from_central(self):
        good, corrupt = self.paths[0].read_bytes(), self.paths[5].read_bytes()
        self.assertEqual(good[30:40], b"Info.plist")
        self.assertEqual(corrupt[30:40], b"Xnfo.plist")
        self.assertEqual(len(good), len(corrupt))

    def test_central_method_differs_from_local(self):
        raw = self.paths[6].read_bytes()
        pos = survey.central_offset(raw)
        self.assertEqual(struct.unpack_from("<H", raw, 8)[0], 8)
        self.assertEqual(struct.unpack_from("<H", raw, pos+10)[0], 0)

    def test_descriptor_crc_differs_from_central(self):
        raw = self.paths[7].read_bytes()
        marker = raw.find(b"PK\x07\x08")
        self.assertGreater(marker, 0)
        eocd = survey.central_offset(raw)
        self.assertNotEqual(struct.unpack_from("<I", raw, marker+4)[0],
                            struct.unpack_from("<I", raw, eocd+16)[0])

    def test_keychain_only_presence_not_contents(self):
        with zipfile.ZipFile(self.paths[8]) as zf:
            self.assertIn("Keychain.plist", zf.namelist())
            self.assertEqual(len(zf.infolist()), 5)

    @unittest.skipUnless(ORIGINAL_FIXTURE.is_file(),
                         "private Crane sample not present in CI")
    def test_original_single_central_header_evidence_only(self):
        with zipfile.ZipFile(ORIGINAL_FIXTURE) as zf:
            self.assertEqual(zf.infolist()[0].filename, "Info.plist")
            self.assertEqual(zf.infolist()[-1].filename, "Metadata.plist")
            self.assertEqual(len(zf.infolist()), 704)


if __name__ == "__main__":
    unittest.main()
