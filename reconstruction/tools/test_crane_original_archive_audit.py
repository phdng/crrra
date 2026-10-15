"""G-11 source-format audit tests (only synthetic ZIPs by default).

Optional local regression can use the reference archive provided by the user.
The file is NEVER checked into Git or included in CI artifacts.
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
import zipfile

from crane_backup_fixture_writer import (
    MARKER, MARKER_CONTENT, write_fixture,
)
from crane_original_archive_audit import audit_original

APP = "com.example.original-audit"
CID = "B2D995A2-531F-468A-9D59-057A8FAC3790"
GROUP = "group.com.example.original-audit"
SECRET = "PRIVATE_ORIGINAL_VALUE_NOT_IN_REPORT"
ORIGINAL_FIXTURE = (Path(__file__).resolve().parents[2] / "backup" /
                    "test_Chrome_bg_10.15.2026_09-25-24.cranect")


class OriginalArchiveAuditTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="crane-original-audit-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / MARKER).write_bytes(MARKER_CONTENT)
        (self.root / "output").mkdir()
        (self.root / "src" / "app").mkdir(parents=True)
        (self.root / "src" / "group").mkdir(parents=True)
        (self.root / "src" / "app" / "example.txt").write_bytes(
            b"harmless synthetic contents")
        (self.root / "src" / "group" / "zero.txt").write_bytes(b"")
        manifest = {
            "containers": [{
                "applicationIdentifier": APP,
                "containerIdentifier": CID,
                "containerName": SECRET,
                "originalPaths": {
                    APP: "/private/var/mobile/FAKE_" + SECRET,
                    GROUP: "/private/var/mobile/group/FAKE_" + SECRET,
                },
                "sourceDirectories": {
                    APP: "src/app", GROUP: "src/group",
                },
            }]
        }
        (self.root / "manifest.json").write_text(
            json.dumps(manifest), encoding="utf8")
        write_fixture(self.root, manifest_name="manifest.json",
                      output_name="synthetic.cranect")
        self.archive = self.root / "output" / "synthetic.cranect"

    def assert_redacted(self, result):
        text = json.dumps(result, sort_keys=True)
        for secret in (APP, CID, GROUP, SECRET, "/private/", "example.txt",
                       "zero.txt", "FAKE_"):
            self.assertNotIn(secret, text)
        self.assertIs(result["keychain_contents_read"], False)
        self.assertIs(result["filesystem_writes"], False)
        self.assertIs(result["original_compatibility_proven"], False)
        self.assertIs(result["restore_safe"], False)

    def _repack(self, *, overrides=None, added=None):
        original = []
        with zipfile.ZipFile(self.archive) as source:
            for item in source.infolist():
                original.append((item, source.read(item)))
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as zf:
            for entry, data in original:
                info = zipfile.ZipInfo(entry.filename)
                info.create_system = entry.create_system
                info.external_attr = entry.external_attr
                info.compress_type = entry.compress_type
                zf.writestr(info, (overrides or {}).get(entry.filename, data))
            for name, data in (added or []):
                zf.writestr(name, data)
        self.archive.write_bytes(out.getvalue())

    def test_synthetic_audit_report_is_redacted(self):
        data = audit_original(self.archive)
        self.assertEqual(data["status"],
                         "original_structure_accepted_not_parity_proof")
        self.assertEqual(data["zip"]["encrypted_members"], 0)
        self.assertEqual(data["container_count"], 1)
        self.assertEqual(data["metadata_observations"][0][
            "orphaned_metadata_records"], 0)
        self.assertEqual(data["metadata_observations"][0][
            "zip_data_without_metadata"], 0)
        self.assertFalse(data["crc_non_keychain_verified"])
        self.assert_redacted(data)

    def test_fixture_metadata_key_counts_are_statically_named(self):
        result = audit_original(self.archive, verify_payload=True)
        observation = result["metadata_observations"][0]
        self.assertTrue(result["crc_non_keychain_verified"])
        self.assertGreater(observation["records"], 0)
        self.assertTrue(all(
            key.startswith("NSFile") for key in
            observation["attribute_presence_counts"]
        ))
        self.assertEqual(observation["attribute_set_variants"], 1)
        self.assert_redacted(result)

    def test_keychain_presence_only_not_contents(self):
        self._repack(added=[("Keychain.plist", SECRET.encode())])
        data = audit_original(self.archive, verify_payload=True)
        self.assertEqual(data["zip"]["keychain_member_count"], 1)
        self.assertEqual(data["status"],
                         "original_structure_accepted_not_parity_proof")
        self.assertTrue(data["crc_non_keychain_verified"])
        self.assert_redacted(data)

    def test_invalid_archive_is_fixed_status_without_member_name(self):
        self._repack(added=[("../" + SECRET + "/secret.txt", b"test")])
        result = audit_original(self.archive)
        self.assertEqual(result["status"],
                         "original_format_inspector_rejected")
        self.assert_redacted(result)

    def test_cli_redacts_all_source_values(self):
        command = [
            sys.executable,
            str(Path(__file__).with_name("crane_original_archive_audit.py")),
            "--archive", str(self.archive), "--verify-payload",
        ]
        done = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        result = json.loads(done.stdout)
        self.assertEqual(result["inspector_status"], "accepted")
        self.assert_redacted(result)
        self.assertNotIn(SECRET, done.stdout + done.stderr)

    @unittest.skipUnless(ORIGINAL_FIXTURE.is_file(),
                         "local user-provided Crane backup not in CI")
    def test_local_genuine_crane_fixture_metadata_and_crc(self):
        result = audit_original(ORIGINAL_FIXTURE, verify_payload=True)
        self.assertEqual(result["status"],
                         "original_structure_accepted_not_parity_proof")
        self.assertEqual(result["zip"]["members"], 704)
        self.assertEqual(result["zip"]["encrypted_members"], 0)
        self.assertEqual(result["zip"]["keychain_member_count"], 0)
        self.assertEqual(result["container_count"], 1)
        self.assertTrue(result["crc_non_keychain_verified"])
        observations = result["metadata_observations"]
        self.assertEqual(observations[0]["records"], 702)
        self.assertEqual(observations[0]["orphaned_metadata_records"], 0)
        self.assertEqual(observations[0]["zip_data_without_metadata"], 0)
        self.assertEqual(observations[0]["attribute_set_variants"], 1)
        self.assertEqual(set(observations[0]["attribute_presence_counts"]), {
            "NSFileCreationDate", "NSFileModificationDate",
            "NSFileExtensionHidden", "NSFileOwnerAccountID",
            "NSFileOwnerAccountName", "NSFileGroupOwnerAccountID",
            "NSFileGroupOwnerAccountName", "NSFilePosixPermissions",
        })
        self.assert_redacted(result)


if __name__ == "__main__":
    unittest.main()
