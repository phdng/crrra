"""G-11 N2: validate fail-closed Python CRC helper on non-native dummy ZIPs."""
from __future__ import annotations

import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

from crane_native_writer_verify import FixtureRejected, validate_native_writer_output

ROOT = Path(__file__).resolve().parents[2]


class NativeWriterVerifierTest(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="crane-n2-")
        self.addCleanup(workspace.cleanup)
        self.folder = Path(workspace.name)

    def path(self, name="fake.cranect"):
        return self.folder / name

    def make_py_zip(self, entries=None):
        result = self.path()
        entries = entries or {
            "Info.plist": plistlib.dumps({
                "applicationIdentifier": "com.example.crane.native",
                "deviceIdentifierForVendor":
                    "00000000-0000-4000-8000-000000000002",
            }),
            "Metadata.plist": plistlib.dumps({}),
        }
        with zipfile.ZipFile(result, "w") as z:
            for key, payload in entries.items():
                z.writestr(key, payload, compress_type=zipfile.ZIP_DEFLATED)
        return result

    def test_normal_zip_without_native_envelope_rejected(self):
        archive = self.make_py_zip()
        with self.assertRaises(FixtureRejected):
            validate_native_writer_output(archive)

    def test_malformed_zip_does_not_pass(self):
        target = self.path()
        target.write_bytes(b"not a zip")
        with self.assertRaises((FixtureRejected, zipfile.BadZipFile)):
            validate_native_writer_output(target)

    def test_unrelated_member_fails_before_any_private_read(self):
        archive = self.make_py_zip({
            "Info.plist": b"BAD",
            "private-not-from-fixture.txt": b"NOT-TO-BE-READ",
        })
        with self.assertRaises(FixtureRejected):
            validate_native_writer_output(archive)

    def test_large_zip_rejected_before_open(self):
        target = self.path()
        target.write_bytes(b"not-a-zip" * (300000))
        with self.assertRaises(FixtureRejected):
            validate_native_writer_output(target)

    def test_symlink_archive_rejected(self):
        real = self.path("real.cranect")
        real.write_bytes(b"not-a-zip")
        linked = self.path()
        try:
            linked.symlink_to(real)
        except (OSError, NotImplementedError) as err:
            self.skipTest(str(err))
        with self.assertRaises(FixtureRejected):
            validate_native_writer_output(linked)

    def test_cli_failure_has_fixed_redacted_status(self):
        archive = self.make_py_zip()
        cli = ROOT / "reconstruction/tools/crane_native_writer_verify.py"
        proc = subprocess.run(
            [sys.executable, str(cli), "--archive", str(archive)],
            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(json.loads(proc.stdout), {
            "status": "native_writer_fixture_rejected",
            "originalCompatibilityProven": False,
            "restoreExecutable": False,
        })
        self.assertNotIn(str(archive), proc.stdout + proc.stderr)

    def test_native_writer_source_is_disposable_only(self):
        source = (ROOT / "reconstruction/sources/prefs/"
                  "CRBackupNativeFixtureWriter.m").read_text(encoding="utf8")
        self.assertIn("WFixtureDirectory(root, &outputFD)", source)
        self.assertIn('CRMarkerBytes[] = "CRANE_DISPOSABLE_FIXTURE_V1\\n"', source)
        self.assertIn("O_EXCL", source)
        self.assertIn("W32(output, 0x08074b50)", source)
        self.assertIn("W16(central, 0x0808)", source)
        self.assertNotIn("SecItemCopyMatching", source)
        self.assertNotIn("CraneManager", source)


if __name__ == "__main__":
    unittest.main()
