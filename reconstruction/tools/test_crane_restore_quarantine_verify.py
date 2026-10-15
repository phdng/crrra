"""G-11 D5: read-only integrity verification of a disposable D4 quarantine."""
from __future__ import annotations

import json
from pathlib import Path
import os
import subprocess
import sys
import unittest
from unittest import mock

import test_crane_restore_fixture_materializer as d4
import crane_restore_quarantine_verify as verifier
from crane_restore_quarantine_verify import (
    VerifyError, verify_quarantine,
)

SECRET = d4.SECRET


class QuarantineVerifyTest(unittest.TestCase):
    def setUp(self):
        # Reuse only D4's synthetic TEMP fixture builder; do not inherit
        # its test cases or duplicate their CI runs.
        self.fixture = d4.MaterializerTest(
            "test_single_archive_materializes_file_bytes_and_empty_paths")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    @property
    def root(self):
        return self.fixture.root

    @property
    def archive(self):
        return self.fixture.archive

    @property
    def inventory(self):
        return self.fixture.inventory

    def published(self):
        return self.fixture.published()

    def run_verify(self):
        return verify_quarantine(self.root, self.archive, self.inventory)

    def private_free(self, report):
        output = json.dumps(report, sort_keys=True)
        for value in (d4.APP, d4.APP2, d4.GROUP, d4.SRC, d4.SRC2,
                      d4.DST, d4.DST2, SECRET, "settings.plist",
                      "empty.txt", "/private/"):
            self.assertNotIn(value, output)
        self.assertIs(report["device_data_touched"], False)
        self.assertIs(report["keychain_contents_read"], False)
        self.assertIs(report["filesystem_writes"], False)
        self.assertIs(report["restore_executable"], False)
        self.assertIs(report["real_rollback_implemented"], False)
        self.assertIs(report["original_compatibility_proven"], False)

    def assert_verified(self, result, expected_files):
        self.assertEqual(result["status"], "fixture_verified_read_only")
        self.assertEqual(result["reason_codes"], [])
        self.assertEqual(result["expected_files"], expected_files)
        self.assertEqual(result["files_hashed"], expected_files)
        self.assertEqual(result["mismatched_files"], 0)
        self.private_free(result)

    def test_single_published_matches_zip_sha256(self):
        self.fixture.run_lab()
        before = (self.archive.read_bytes(), self.inventory.read_bytes())
        result = self.run_verify()
        self.assert_verified(result, 2)
        self.assertGreater(result["expected_directories"], 0)
        self.assertEqual((self.archive.read_bytes(),
                          self.inventory.read_bytes()), before)

    def test_multi_all_containers_verified(self):
        self.fixture.multi()
        self.fixture.run_lab()
        result = self.run_verify()
        self.assert_verified(result, 4)
        self.assertGreater(result["expected_directories"], 6)

    def test_multi_subset_is_verified_without_unmapped_paths(self):
        self.fixture.multi()
        self.fixture.set_inventory(
            [d4.target(d4.APP, d4.DST)],
            [d4.mapping(d4.APP, d4.SRC, d4.DST)])
        self.fixture.run_lab()
        self.assert_verified(self.run_verify(), 2)

    def test_tampered_equal_size_file_is_detected(self):
        self.fixture.run_lab()
        target = next(self.published().rglob("settings.plist"))
        raw = target.read_bytes()
        target.write_bytes(b"x" + raw[1:])
        self.assertEqual(len(target.read_bytes()), len(raw))
        report = self.run_verify()
        self.assertEqual(report["status"], "fixture_integrity_mismatch")
        self.assertIn("file_content_or_length_mismatch",
                      report["reason_codes"])
        self.assertEqual(report["mismatched_files"], 1)
        self.private_free(report)
        self.assertEqual(target.read_bytes(), b"x" + raw[1:])

    def test_truncated_file_detected(self):
        self.fixture.run_lab()
        target = next(self.published().rglob("settings.plist"))
        target.write_bytes(b"TOO_SHORT")
        report = self.run_verify()
        self.assertIn("file_content_or_length_mismatch",
                      report["reason_codes"])
        self.assertEqual(report["mismatched_files"], 1)
        self.private_free(report)

    def test_removed_payload_file_is_detected(self):
        self.fixture.run_lab()
        target = next(self.published().rglob("settings.plist"))
        target.unlink()
        report = self.run_verify()
        self.assertEqual(report["missing_files"], 1)
        self.assertIn("missing_files", report["reason_codes"])
        self.private_free(report)

    def test_extra_file_is_detected_but_not_opened(self):
        self.fixture.run_lab()
        (self.published() / "private-not-in-zip.txt").write_bytes(
            SECRET.encode())
        report = self.run_verify()
        self.assertEqual(report["unexpected_files"], 1)
        self.assertIn("unexpected_files", report["reason_codes"])
        self.private_free(report)

    def test_extra_directory_is_detected(self):
        self.fixture.run_lab()
        (self.published() / "untracked-extra").mkdir()
        report = self.run_verify()
        self.assertEqual(report["unexpected_directories"], 1)
        self.assertIn("unexpected_directories", report["reason_codes"])
        self.private_free(report)

    def test_missing_empty_directory_is_detected(self):
        self.fixture.run_lab()
        missing = next(self.published().rglob("EmptyFolder"))
        missing.rmdir()
        report = self.run_verify()
        self.assertEqual(report["missing_directories"], 1)
        self.assertIn("missing_directories", report["reason_codes"])
        self.private_free(report)

    def test_symlink_file_not_followed(self):
        self.fixture.run_lab()
        path = next(self.published().rglob("settings.plist"))
        external = self.root / "one" / "app" / "Library" / "Preferences" / "settings.plist"
        original = external.read_bytes()
        path.unlink()
        try:
            path.symlink_to(external)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlinks unsupported: {exc}")
        report = self.run_verify()
        self.assertIn("unsafe_file_entry", report["reason_codes"])
        self.assertIn("missing_files", report["reason_codes"])
        self.assertEqual(external.read_bytes(), original)
        self.private_free(report)

    def test_symlink_directory_not_traversed(self):
        self.fixture.run_lab()
        folder = next(self.published().rglob("EmptyFolder"))
        folder.rmdir()
        try:
            folder.symlink_to(self.root / "one" / "app",
                              target_is_directory=True)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlinks unsupported: {exc}")
        report = self.run_verify()
        self.assertIn("unsafe_directory_entry", report["reason_codes"])
        self.assertIn("missing_directories", report["reason_codes"])
        self.private_free(report)

    def test_hardlinked_output_is_detected(self):
        self.fixture.run_lab()
        path = next(self.published().rglob("settings.plist"))
        link = self.root / "disposable-link.txt"
        try:
            os.link(path, link)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"hardlinks unsupported: {exc}")
        report = self.run_verify()
        self.assertIn("linked_output_file", report["reason_codes"])
        self.private_free(report)

    def test_invalid_stage_marker_is_not_reported_clean(self):
        self.fixture.run_lab()
        marker = self.published() / ".crane-stage"
        marker.write_bytes(b"FORGED")
        report = self.run_verify()
        self.assertEqual(report["status"], "fixture_integrity_mismatch")
        self.assertIn("marker_invalid", report["reason_codes"])
        self.private_free(report)

    def test_unpublished_batch_is_rejected(self):
        with self.assertRaises(VerifyError):
            self.run_verify()

    def test_unexpected_extra_published_batch_is_rejected(self):
        self.fixture.run_lab()
        (self.fixture.lab / "published" / "other").mkdir()
        with self.assertRaises(VerifyError):
            self.run_verify()

    def test_blocked_preflight_is_rejected(self):
        self.fixture.run_lab()
        self.fixture.set_inventory(
            [d4.target(d4.APP, d4.DST, active=True)],
            [d4.mapping(d4.APP, d4.SRC, d4.DST)])
        with self.assertRaises(VerifyError):
            self.run_verify()

    def test_archive_outside_expected_output_is_rejected(self):
        self.fixture.run_lab()
        outside = self.root / "another.cranect"
        outside.write_bytes(self.archive.read_bytes())
        with self.assertRaises(Exception):
            verify_quarantine(self.root, outside, self.inventory)

    def test_source_replacement_during_hash_is_refused(self):
        self.fixture.run_lab()
        digest = verifier._digest_member
        modified = [False]

        def touch_during_digest(zf, member):
            if not modified[0]:
                st = self.archive.stat()
                os.utime(self.archive, ns=(st.st_atime_ns,
                                           st.st_mtime_ns + 2_000_000_000))
                modified[0] = True
            return digest(zf, member)

        with mock.patch.object(verifier, "_digest_member",
                               side_effect=touch_during_digest):
            with self.assertRaises(VerifyError):
                self.run_verify()
        self.assertTrue(modified[0])

    def test_read_only_guard_against_mutators(self):
        self.fixture.run_lab()
        def deny(*args, **kwargs):
            raise AssertionError("verifier attempted filesystem mutation")
        with mock.patch("os.rename", side_effect=deny), \
             mock.patch("os.replace", side_effect=deny), \
             mock.patch("os.unlink", side_effect=deny):
            result = self.run_verify()
        self.assert_verified(result, 2)

    def test_cli_success_mismatch_and_redaction(self):
        self.fixture.run_lab()
        cli = Path(__file__).with_name("crane_restore_quarantine_verify.py")
        command = [sys.executable, str(cli),
                   "--fixture-root", str(self.root),
                   "--archive", str(self.archive),
                   "--inventory", str(self.inventory)]
        success = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(json.loads(success.stdout)["status"],
                         "fixture_verified_read_only")
        self.assertNotIn(d4.APP, success.stdout)
        self.assertNotIn(SECRET, success.stdout + success.stderr)

        next(self.published().rglob("settings.plist")).write_bytes(b"MUTATED")
        mismatch = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(mismatch.returncode, 1, mismatch.stderr)
        self.assertEqual(json.loads(mismatch.stdout)["status"],
                         "fixture_integrity_mismatch")
        self.assertNotIn(SECRET, mismatch.stdout + mismatch.stderr)

    def test_cli_invalid_input_redacted(self):
        self.fixture.run_lab()
        cli = Path(__file__).with_name("crane_restore_quarantine_verify.py")
        (self.fixture.lab / d4.LAB_MARKER).write_bytes(SECRET.encode())
        response = subprocess.run([
            sys.executable, str(cli), "--fixture-root", str(self.root),
            "--archive", str(self.archive),
            "--inventory", str(self.inventory)],
            capture_output=True, text=True)
        self.assertEqual(response.returncode, 2, response.stderr)
        self.assertEqual(json.loads(response.stdout)["status"],
                         "fixture_verify_invalid_or_unavailable")
        self.assertNotIn(SECRET, response.stdout + response.stderr)


if __name__ == "__main__":
    unittest.main()
