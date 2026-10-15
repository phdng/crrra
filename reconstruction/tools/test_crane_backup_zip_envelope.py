"""G-11 C5 ZIP envelope tests, structural only; original Chrome sample optional.

All generated input is disposable synthetic test data. Never open Chrome
payload bytes or Keychain. Exact original ZIP64 extras remain unsupported.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import unittest
import zipfile

from crane_backup_zip_envelope import (
    EnvelopeUnavailable, _extra_fields, compare_envelopes,
    zip_envelope_profile,
)
import crane_backup_fixture_writer as writer
import test_crane_backup_fixture_writer as fixture_tests
from test_crane_original_archive_audit import ORIGINAL_FIXTURE


class ZipEnvelopeTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixture_tests.WriterTest(
            "test_single_binary_manifest_and_roundtrip_crc")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.manifest()

    def make(self, name="candidate.cranect", *, zip_layout="standard",
             metadata_profile="host-stat"):
        result = writer.write_fixture(
            self.fixture.root, manifest_name="manifest.json",
            output_name=name, zip_layout=zip_layout,
            metadata_profile=metadata_profile)
        self.assertFalse(result["original_zip_envelope_proven"])
        self.assertFalse(result["original_compatibility_proven"])
        return self.fixture.output / name

    def assert_private_safe(self, profile):
        dumped = json.dumps(profile)
        for value in (fixture_tests.APP, fixture_tests.CID,
                      fixture_tests.GROUP, "settings.plist", "group.txt",
                      "/private/", "TEST"):
            self.assertNotIn(value, dumped)
        self.assertIs(profile["original_compatibility_proven"], False)
        self.assertIs(profile["restore_safe"], False)
        self.assertIs(profile["filesystem_writes"], False)

    def test_observed_layout_has_info_first_metadata_last(self):
        path = self.make(zip_layout="original-observed-structure")
        result = zip_envelope_profile(path)
        self.assertTrue(result["info_first"])
        self.assertTrue(result["metadata_last"])
        with zipfile.ZipFile(path) as zf:
            self.assertEqual(zf.namelist()[0], "Info.plist")
            self.assertEqual(zf.namelist()[-1], "Metadata.plist")
        self.assert_private_safe(result)

    def test_observed_layout_uses_store_for_directories_deflate_files(self):
        profile = zip_envelope_profile(self.make(
            zip_layout="original-observed-structure"))
        self.assertTrue(profile["directories_stored"])
        self.assertTrue(profile["files_deflated"])
        self.assertGreater(profile["directories"], 0)
        self.assertGreater(profile["files"], 0)

    def test_observed_layout_uses_original_creator19(self):
        profile = zip_envelope_profile(self.make(
            zip_layout="original-observed-structure"))
        self.assertTrue(profile["all_macos_creator_19"])
        self.assertEqual(profile["macos_creator_19_entries"],
                         profile["total_entries"])

    def test_unimplemented_zip64_flag_parity_remains_explicitly_false(self):
        observed = zip_envelope_profile(self.make(
            zip_layout="original-observed-structure"))
        self.assertFalse(observed["all_general_flag_0808"])
        self.assertFalse(observed["all_zip64_16_extra"])
        self.assertFalse(observed["all_requires_zip64_version_45"])
        self.assert_private_safe(observed)

    def test_default_writer_keeps_existing_ordering_and_compression(self):
        default = zip_envelope_profile(self.make())
        self.assertFalse(default["metadata_last"])
        self.assertFalse(default["directories_stored"])
        self.assertFalse(default["all_macos_creator_19"])
        self.assert_private_safe(default)

    def test_original_observed_layout_rejects_unproven_multi(self):
        self.fixture.manifest(self.fixture.rows + [
            fixture_tests.container(fixture_tests.OTHER_APP,
                                    fixture_tests.CID2, "two")])
        target = self.fixture.output / "unsupported.cranebk"
        with self.assertRaises(writer.FixtureError):
            writer.write_fixture(
                self.fixture.root, manifest_name="manifest.json",
                output_name=target.name,
                zip_layout="original-observed-structure")
        self.assertFalse(target.exists())

    def test_unknown_zip_layout_rejected_before_output(self):
        target = self.fixture.output / "bad.cranect"
        with self.assertRaises(writer.FixtureError):
            writer.write_fixture(
                self.fixture.root, manifest_name="manifest.json",
                output_name=target.name, zip_layout="force-zip64-unverified")
        self.assertFalse(target.exists())

    def test_eight_field_profile_and_observed_layout_can_combine(self):
        output = self.make(
            zip_layout="original-observed-structure",
            metadata_profile="synthetic-original-eight-field")
        result = zip_envelope_profile(output)
        self.assertTrue(result["metadata_last"])
        self.assertTrue(result["directories_stored"])
        with zipfile.ZipFile(output) as zf:
            import plistlib
            attrs = plistlib.loads(zf.read("Metadata.plist"))
            self.assertTrue(attrs)
            self.assertEqual(len(next(iter(attrs.values()))), 8)

    def test_independent_matching_synthetic_envelopes_not_authenticity(self):
        left = self.make("one.cranect", zip_layout="original-observed-structure")
        right = self.make("two.cranect", zip_layout="original-observed-structure")
        comparison = compare_envelopes(left, right)
        self.assertEqual(comparison["difference_count"], 0)
        self.assertEqual(comparison["status"],
                         "zip_envelope_features_match_not_proven")
        self.assert_private_safe(comparison)

    def test_detects_layout_disagreement_without_identity_leak(self):
        original_style = self.make("style.cranect",
                                   zip_layout="original-observed-structure")
        basic = self.make("basic.cranect")
        outcome = compare_envelopes(original_style, basic)
        self.assertIn("metadata_last", outcome["different_feature_names"])
        self.assertIn("directories_stored", outcome["different_feature_names"])
        self.assertIn("all_macos_creator_19",
                      outcome["different_feature_names"])
        self.assert_private_safe(outcome)

    def test_no_overwrite_and_source_bytes_unchanged(self):
        source = self.fixture.root / "one/app/Library/Preferences/settings.plist"
        previous = source.read_bytes()
        path = self.make(zip_layout="original-observed-structure")
        old_zip = path.read_bytes()
        with self.assertRaises(writer.FixtureError):
            self.make(zip_layout="original-observed-structure")
        self.assertEqual(source.read_bytes(), previous)
        self.assertEqual(path.read_bytes(), old_zip)

    def test_extra_parser_rejects_truncation(self):
        for sample in (b"\x01", b"\x01\x00\x10\x00junk"):
            with self.subTest(sample=sample):
                with self.assertRaises(EnvelopeUnavailable):
                    _extra_fields(sample)
        self.assertEqual(_extra_fields(b"\x01\x00\x10\x00" + b"x" * 16),
                         (1, 0, 20))

    def test_cli_reports_only_headers_and_fixed_feature_names(self):
        cli = Path(__file__).with_name("crane_backup_zip_envelope.py")
        candidate = self.make(zip_layout="original-observed-structure")
        args = [sys.executable, str(cli), "--reference", str(candidate)]
        response = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(response.returncode, 0, response.stderr)
        self.assert_private_safe(json.loads(response.stdout))
        second = self.make("simple.cranect")
        compared = subprocess.run(
            args + ["--candidate", str(second)],
            capture_output=True, text=True)
        self.assertEqual(compared.returncode, 1)
        self.assertEqual(json.loads(compared.stdout)["status"],
                         "zip_envelope_features_differ")
        self.assertNotIn(fixture_tests.APP, compared.stdout)

    def test_cli_rejects_same_file_and_privately_reports_error(self):
        cli = Path(__file__).with_name("crane_backup_zip_envelope.py")
        path = self.make()
        result = subprocess.run(
            [sys.executable, str(cli), "--reference", str(path),
             "--candidate", str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["status"],
                         "zip_envelope_unavailable_or_invalid")

    @unittest.skipUnless(ORIGINAL_FIXTURE.is_file(),
                         "optional local original Chrome archive, never CI")
    def test_genuine_single_backup_envelope_counts(self):
        original = zip_envelope_profile(ORIGINAL_FIXTURE)
        self.assertEqual(original["total_entries"], 704)
        self.assertEqual(original["files"], 501)
        self.assertEqual(original["directories"], 203)
        for feature in (
            "info_first", "metadata_last", "directories_stored",
            "files_deflated", "all_macos_creator_19",
            "all_general_flag_0808", "all_zip64_16_extra",
            "all_requires_zip64_version_45",
        ):
            self.assertTrue(original[feature], feature)
        self.assertEqual(original["other_extra_fields"], 0)
        self.assert_private_safe(original)

    @unittest.skipUnless(ORIGINAL_FIXTURE.is_file(),
                         "optional real archive, synthetic CI sufficient")
    def test_original_vs_fixture_exposes_unimplemented_envelope_parts(self):
        candidate = self.make(zip_layout="original-observed-structure")
        result = compare_envelopes(ORIGINAL_FIXTURE, candidate)
        self.assertEqual(set(result["different_feature_names"]), {
            "all_general_flag_0808",
            "all_zip64_16_extra",
            "all_requires_zip64_version_45",
        })
        self.assertEqual(result["difference_count"], 3)
        self.assert_private_safe(result)


if __name__ == "__main__":
    unittest.main()
