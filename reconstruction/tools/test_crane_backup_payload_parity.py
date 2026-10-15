"""G-11 C2: redacted SHA-256 equivalence of NON-KEYCHAIN ZIP payloads.

All archives in this test are generated from explicitly disposable synthetic
fixtures. A matching digest is NEVER evidence of original Crane provenance.
"""
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

import crane_backup_payload_parity as parity
from crane_backup_payload_parity import ParityUnavailable, compare_payloads
import test_crane_backup_shape_compare as shape_fixture

APP, APP2 = shape_fixture.APP, shape_fixture.APP2
CID, CID2 = shape_fixture.CID, shape_fixture.CID2
GROUP, SECRET = shape_fixture.GROUP, shape_fixture.SECRET
replace_members = shape_fixture.replace_members


class PayloadParityTest(unittest.TestCase):
    def setUp(self):
        self.fixture = shape_fixture.ComparatorTest(
            "test_identical_shape_even_when_different_zip_files")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.reference = self.fixture.root / "output/reference.cranect"
        self.candidate = self.fixture.root / "output/candidate.cranect"

    def check_private(self, result):
        serial = json.dumps(result, sort_keys=True)
        for private in (APP, APP2, GROUP, CID, CID2, SECRET,
                        "/private/", "safefile.txt", "group/empty"):
            self.assertNotIn(private, serial)
        self.assertIs(result["original_compatibility_proven"], False)
        self.assertIs(result["restore_safe"], False)
        if result.get("comparison_completed"):
            self.assertIs(result["keychain_contents_read"], False)
            self.assertIs(result["files_extracted"], False)
            self.assertIs(result["filesystem_writes"], False)

    def test_identical_unencrypted_single_has_byte_match_not_proof(self):
        before = (self.reference.read_bytes(), self.candidate.read_bytes())
        result = compare_payloads(self.reference, self.candidate)
        self.assertEqual(result["status"],
                         "payload_and_metadata_bytes_match_not_proven")
        self.assertTrue(result["comparison_completed"])
        self.assertTrue(result["payload_tree_equal"])
        self.assertTrue(result["metadata_serialized_bytes_equal"])
        self.assertTrue(result["crc_checked_both_non_keychain"])
        self.assertGreater(result["compared_file_count"], 0)
        self.assertEqual(result["different_plist_bytes"], 0)
        self.assertEqual((self.reference.read_bytes(),
                          self.candidate.read_bytes()), before)
        self.check_private(result)

    def test_same_size_payload_mutation_detected_even_if_shape_matches(self):
        filename = f"{APP}/safefile.txt"
        with zipfile.ZipFile(self.candidate) as zf:
            raw = zf.read(filename)
        replace_members(self.candidate, {filename: b"Z" + raw[1:]})
        result = compare_payloads(self.reference, self.candidate)
        self.assertEqual(result["shape_difference_count"], 0)
        self.assertEqual(result["equal_size_content_mismatches"], 1)
        self.assertFalse(result["payload_tree_equal"])
        self.assertEqual(result["status"], "payload_or_metadata_differences")
        self.check_private(result)

    def test_size_mismatch_detected_without_exposing_path(self):
        replace_members(self.candidate, {f"{APP}/safefile.txt": b"TWO BYTES MORE"})
        result = compare_payloads(self.reference, self.candidate)
        self.assertEqual(result["file_size_mismatches"], 1)
        self.assertEqual(result["equal_size_content_mismatches"], 0)
        self.check_private(result)

    def test_additional_and_missing_files_report_only_counts(self):
        replace_members(self.candidate, {}, appended=[
            (f"{APP}/new-hidden-file.txt", b"NONPRIVATE")])
        result = compare_payloads(self.reference, self.candidate)
        self.assertEqual(result["extra_candidate_files"], 1)
        self.check_private(result)

    def test_new_explicit_directory_reported_without_name(self):
        replace_members(self.candidate, {}, appended=[(f"{APP}/brand-new/", b"")])
        result = compare_payloads(self.reference, self.candidate)
        self.assertEqual(result["extra_candidate_directories"], 1)
        self.check_private(result)

    def test_metadata_value_change_detected_beyond_shape_fields(self):
        with zipfile.ZipFile(self.candidate) as zf:
            original = plistlib.loads(zf.read("Info.plist"))
        original["containerName"] = SECRET + " CHANGED"
        replace_members(self.candidate, {"Info.plist": plistlib.dumps(
            original, fmt=plistlib.FMT_BINARY)})
        result = compare_payloads(self.reference, self.candidate)
        self.assertTrue(result["payload_tree_equal"])
        self.assertEqual(result["shape_difference_count"], 0)
        self.assertEqual(result["different_plist_bytes"], 1)
        self.assertFalse(result["metadata_serialized_bytes_equal"])
        self.check_private(result)

    def test_compression_method_diff_even_with_identical_extracted_bytes(self):
        replace_members(self.candidate, {}, compress_type=zipfile.ZIP_STORED)
        result = compare_payloads(self.reference, self.candidate)
        self.assertTrue(result["payload_tree_equal"])
        self.assertGreater(result["shape_difference_count"], 0)
        self.assertEqual(result["status"], "payload_or_metadata_differences")
        self.check_private(result)

    def test_keychain_present_in_both_is_never_opened(self):
        replace_members(self.reference, {}, appended=[
            ("Keychain.plist", b"REFERENCE_" + SECRET.encode())])
        replace_members(self.candidate, {}, appended=[
            ("Keychain.plist", b"CANDIDATE_" + SECRET.encode())])
        real_open = zipfile.ZipFile.open

        def no_keychain_open(zf, member, *args, **kwargs):
            name = member.filename if isinstance(member, zipfile.ZipInfo) else member
            if name.endswith("Keychain.plist"):
                raise AssertionError("Keychain content must remain unopened")
            return real_open(zf, member, *args, **kwargs)

        with mock.patch.object(zipfile.ZipFile, "open", new=no_keychain_open):
            result = compare_payloads(self.reference, self.candidate)
        self.assertEqual(result["keychain_entries_not_compared"], 2)
        self.assertTrue(result["payload_tree_equal"])
        self.check_private(result)

    def test_keychain_presence_discrepancy_in_shape_only(self):
        replace_members(self.candidate, {}, appended=[
            ("Keychain.plist", SECRET.encode())])
        result = compare_payloads(self.reference, self.candidate)
        self.assertTrue(result["payload_tree_equal"])
        self.assertGreater(result["shape_difference_count"], 0)
        self.assertEqual(result["keychain_entries_not_compared"], 1)
        self.check_private(result)

    def test_multi_container_independent_of_index_order(self):
        left = self.fixture.make("reference.cranebk", multi=True)
        right = self.fixture.make("candidate.cranebk", multi=True)
        result = compare_payloads(left, right)
        self.assertEqual(result["status"],
                         "payload_and_metadata_bytes_match_not_proven")
        self.assertTrue(result["payload_tree_equal"])
        self.assertGreater(result["compared_file_count"], 1)
        self.check_private(result)

    def test_kind_mismatch_inconclusive_not_pass(self):
        multi = self.fixture.make("candidate.cranebk", multi=True)
        result = compare_payloads(self.reference, multi)
        self.assertEqual(result["status"],
                         "container_identity_or_kind_mismatch_uncompared")
        self.assertFalse(result["comparison_completed"])
        self.check_private(result)

    def test_container_id_mismatch_inconclusive(self):
        with zipfile.ZipFile(self.candidate) as zf:
            original = plistlib.loads(zf.read("Info.plist"))
        original["containerIdentifier"] = CID2
        replace_members(self.candidate, {
            "Info.plist": plistlib.dumps(original, fmt=plistlib.FMT_BINARY)})
        result = compare_payloads(self.reference, self.candidate)
        self.assertEqual(result["status"],
                         "container_identity_or_kind_mismatch_uncompared")
        self.check_private(result)

    def test_same_file_not_independent_evidence(self):
        with self.assertRaises(ParityUnavailable):
            compare_payloads(self.reference, self.reference)

    def test_original_zip_invalid_path_is_not_accepted(self):
        replace_members(self.candidate, {}, appended=[
            ("../" + SECRET + "/bad.txt", b"EXAMPLE")])
        cli = Path(parity.__file__)
        result = subprocess.run([
            sys.executable, str(cli), "--reference", str(self.reference),
            "--candidate", str(self.candidate)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["status"],
                         "parity_unavailable_or_unsupported")
        self.assertNotIn(SECRET, result.stdout + result.stderr)

    def test_inspector_crc_budget_cannot_be_bypassed(self):
        with mock.patch("crane_backup_inspector.MAX_VERIFY_BYTES", 1):
            from crane_backup_inspector import UnsupportedArchive
            with self.assertRaises(UnsupportedArchive):
                compare_payloads(self.reference, self.candidate)

    def test_cli_exit_status_and_redaction(self):
        cli = Path(parity.__file__)
        args = [sys.executable, str(cli), "--reference", str(self.reference),
                "--candidate", str(self.candidate)]
        initial = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(initial.returncode, 0, initial.stderr)
        self.assertEqual(json.loads(initial.stdout)["status"],
                         "payload_and_metadata_bytes_match_not_proven")
        self.assertNotIn(APP, initial.stdout)
        with zipfile.ZipFile(self.candidate) as zf:
            raw = zf.read(f"{APP}/safefile.txt")
        replace_members(self.candidate,
                        {f"{APP}/safefile.txt": b"Z" + raw[1:]})
        mismatch = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(mismatch.returncode, 1, mismatch.stderr)
        self.assertEqual(json.loads(mismatch.stdout)["status"],
                         "payload_or_metadata_differences")
        self.assertNotIn(APP, mismatch.stdout + mismatch.stderr)

    def test_archive_modified_during_hash_is_refused(self):
        original = parity._member_digest
        touched = [False]

        def disrupt(zf, item, limit):
            if not touched[0] and item.filename.endswith("safefile.txt"):
                touched[0] = True
                import os
                st = self.reference.stat()
                os.utime(self.reference,
                         ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
            return original(zf, item, limit)
        with mock.patch.object(parity, "_member_digest",
                               side_effect=disrupt):
            with self.assertRaises(ParityUnavailable):
                compare_payloads(self.reference, self.candidate)
        self.assertTrue(touched[0])


if __name__ == "__main__":
    unittest.main()
