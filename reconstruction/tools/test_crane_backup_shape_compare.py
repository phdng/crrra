"""G-11 read-only, redacted shape comparisons on disposable synthetic archives.

Do NOT depend on genuine user backups or include personal fixture records.
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

import crane_backup_fixture_writer as fixture_writer
from crane_backup_shape_compare import compare_archives, archive_profile

APP = "com.example.fixture"
GROUP = "group.com.example.fixture"
APP2 = "org.example.fixture"
CID = "0BE4F187-91AA-4A04-B3CB-F80E5A33E231"
CID2 = "AAC79098-6941-4BD9-A4FD-32C0BD149341"
SECRET = "PRIVATE_NEVER_IN_OUTPUT"


def entries_from_zip(path: Path) -> list[tuple[zipfile.ZipInfo, bytes]]:
    with zipfile.ZipFile(path, "r") as archive:
        return [(entry, archive.read(entry))
                for entry in archive.infolist()]


def replace_members(path: Path, overrides: dict[str, bytes], *,
                    compress_type: int | None = None,
                    appended: list[tuple[str, bytes]] | None = None):
    entries = entries_from_zip(path)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for original, contents in entries:
            name = original.filename
            info = zipfile.ZipInfo(name)
            info.create_system = original.create_system
            info.external_attr = original.external_attr
            info.compress_type = (original.compress_type
                                  if compress_type is None else compress_type)
            archive.writestr(info, overrides.get(name, contents))
        for name, contents in (appended or []):
            archive.writestr(name, contents,
                             compress_type=compress_type or zipfile.ZIP_DEFLATED)
    path.write_bytes(buffer.getvalue())


class ComparatorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="crane-compare-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / fixture_writer.MARKER).write_bytes(
            fixture_writer.MARKER_CONTENT)
        (self.root / "output").mkdir()
        (self.root / "demo" / "app").mkdir(parents=True)
        (self.root / "demo" / "group").mkdir(parents=True)
        (self.root / "demo" / "app" / "safefile.txt").write_text(
            "NONPRIVATE DATA", encoding="utf-8")
        (self.root / "demo" / "group" / "empty").write_bytes(b"")
        self.manifest = {
            "containers": [{
                "applicationIdentifier": APP,
                "containerIdentifier": CID,
                "containerName": SECRET,
                "originalPaths": {
                    APP: "/private/var/mobile/" + SECRET,
                    GROUP: "/private/var/mobile/group/" + SECRET,
                },
                "sourceDirectories": {
                    APP: "demo/app",
                    GROUP: "demo/group",
                }
            }]
        }
        self.make("reference.cranect")
        self.make("candidate.cranect")

    def make(self, name: str, *, multi: bool = False) -> Path:
        if multi:
            manifest = {"containers": [self.manifest["containers"][0], {
                **self.manifest["containers"][0],
                "applicationIdentifier": APP2,
                "containerIdentifier": CID2,
                "originalPaths": {
                    APP2: "/private/var/mobile/" + SECRET,
                    GROUP: "/private/var/mobile/group/" + SECRET,
                },
                "sourceDirectories": {
                    APP2: "demo/app", GROUP: "demo/group",
                }
            }]}
        else:
            manifest = self.manifest
        (self.root / "manifest.json").write_text(json.dumps(manifest),
                                                 encoding="utf-8")
        fixture_writer.write_fixture(self.root, manifest_name="manifest.json",
                                     output_name=name)
        return self.root / "output" / name

    def assert_private(self, data: dict) -> None:
        emitted = json.dumps(data, sort_keys=True)
        for secret in (SECRET, APP, APP2, GROUP, CID, CID2, "/private/",
                       "safefile.txt", "/empty"):
            self.assertNotIn(secret, emitted)

    def test_identical_shape_even_when_different_zip_files(self):
        result = compare_archives(self.root / "output/reference.cranect",
                                  self.root / "output/candidate.cranect",
                                  verify_payload=True)
        self.assertEqual(result["status"],
                         "structural_shape_match_not_proven")
        self.assertEqual(result["difference_count"], 0)
        self.assertTrue(result["non_keychain_crc_verified"])
        self.assertFalse(result["original_compatibility_proven"])
        self.assertFalse(result["restore_safe"])
        self.assertFalse(result["keychain_contents_read"])
        self.assertFalse(result["extracted"])
        self.assert_private(result)

    def test_multi_container_order_independent(self):
        a = self.make("reference.cranebk", multi=True)
        b = self.make("candidate.cranebk", multi=True)
        result = compare_archives(a, b)
        self.assertEqual(result["difference_count"], 0)
        self.assertEqual(archive_profile(a)["container_count"], 2)
        self.assert_private(result)

    def test_mismatch_metadata_keys_is_structural_only(self):
        target = self.root / "output/candidate.cranect"
        with zipfile.ZipFile(target) as zf:
            original = plistlib.loads(zf.read("Metadata.plist"))
        original[next(iter(original))]["NSFileImmutable"] = True
        replace_members(target, {"Metadata.plist": plistlib.dumps(
            original, fmt=plistlib.FMT_BINARY)})
        result = compare_archives(self.root / "output/reference.cranect", target)
        self.assertEqual(result["status"], "structural_differences_found")
        self.assertGreater(result["difference_count"], 0)
        self.assertIn("containers",
                      json.dumps(result["differences"]))
        self.assert_private(result)

    def test_unknown_sensitive_plist_field_is_only_counted(self):
        target = self.root / "output/candidate.cranect"
        with zipfile.ZipFile(target) as zf:
            content = plistlib.loads(zf.read("Info.plist"))
        content[SECRET + "_CUSTOM_FIELD"] = SECRET
        replace_members(target, {"Info.plist": plistlib.dumps(
            content, fmt=plistlib.FMT_BINARY)})
        compared = compare_archives(
            self.root / "output/reference.cranect", target)
        self.assertTrue(any(
            "unrecognized_field_count" in change["field"]
            for change in compared["differences"]))
        self.assert_private(compared)

    def test_xml_plist_difference_detected(self):
        target = self.root / "output/candidate.cranect"
        with zipfile.ZipFile(target) as zf:
            content = plistlib.loads(zf.read("Info.plist"))
        replace_members(target, {"Info.plist": plistlib.dumps(
            content, fmt=plistlib.FMT_XML)})
        result = compare_archives(self.root / "output/reference.cranect", target)
        self.assertTrue(any(".format" in issue["field"]
                            for issue in result["differences"]))
        self.assert_private(result)

    def test_different_compression_method_detected(self):
        target = self.root / "output/candidate.cranect"
        replace_members(target, {}, compress_type=zipfile.ZIP_STORED)
        result = compare_archives(self.root / "output/reference.cranect", target)
        self.assertTrue(any("methods" in issue["field"]
                            for issue in result["differences"]))
        self.assert_private(result)

    def test_detects_keychain_presence_without_reading_contents(self):
        target = self.root / "output/candidate.cranect"
        replace_members(target, {}, appended=[
            ("Keychain.plist", SECRET.encode())])
        result = compare_archives(self.root / "output/reference.cranect", target,
                                  verify_payload=True)
        self.assertFalse(result["keychain_contents_read"])
        self.assertTrue(result["non_keychain_crc_verified"])
        self.assertTrue(any("keychain_present" in issue["field"]
                            for issue in result["differences"]))
        self.assert_private(result)

    def test_same_file_is_not_evidence(self):
        path = self.root / "output/reference.cranect"
        from crane_backup_shape_compare import ComparisonUnavailable
        with self.assertRaises(ComparisonUnavailable):
            compare_archives(path, path)

    def test_different_kind_is_reported(self):
        multi = self.make("candidate.cranebk", multi=True)
        result = compare_archives(self.root / "output/reference.cranect", multi)
        self.assertTrue(any(issue["field"] == "kind"
                            for issue in result["differences"]))
        self.assert_private(result)

    def test_cli_privacy_and_different_statuses(self):
        cli = Path(__file__).with_name("crane_backup_shape_compare.py")
        a, b = (self.root / "output/reference.cranect",
                self.root / "output/candidate.cranect")
        arguments = [sys.executable, str(cli), "--reference", str(a),
                     "--candidate", str(b), "--verify-payload"]
        matched = subprocess.run(arguments, capture_output=True, text=True)
        self.assertEqual(matched.returncode, 0, matched.stderr)
        self.assertEqual(json.loads(matched.stdout)["status"],
                         "structural_shape_match_not_proven")
        self.assertNotIn(SECRET, matched.stdout)
        replace_members(b, {}, appended=[
            (f"{APP}/additional.txt", b"fixture")])
        mismatch = subprocess.run(arguments, capture_output=True, text=True)
        self.assertEqual(mismatch.returncode, 1, mismatch.stderr)
        self.assertEqual(json.loads(mismatch.stdout)["status"],
                         "structural_differences_found")
        self.assertNotIn(APP, mismatch.stdout)

    def test_cli_redacts_invalid_archive_entry_names(self):
        cli = Path(__file__).with_name("crane_backup_shape_compare.py")
        reference = self.root / "output/reference.cranect"
        target = self.root / "output/candidate.cranect"
        replace_members(target, {}, appended=[
            ("../" + SECRET + "/danger.txt", b"invalid")])
        result = subprocess.run([
            sys.executable, str(cli), "--reference", str(reference),
            "--candidate", str(target)
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["status"],
                         "unavailable_or_invalid")
        self.assertNotIn(SECRET, result.stdout)
        self.assertNotIn(SECRET, result.stderr)

    def test_input_sources_not_changed(self):
        a = self.root / "output/reference.cranect"
        b = self.root / "output/candidate.cranect"
        before = a.read_bytes(), b.read_bytes()
        compare_archives(a, b, verify_payload=True)
        self.assertEqual((a.read_bytes(), b.read_bytes()), before)


if __name__ == "__main__":
    unittest.main()
