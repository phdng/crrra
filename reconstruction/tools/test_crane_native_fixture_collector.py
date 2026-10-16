"""N4 test-only native source collection contracts + redacted CRC verifier.

Valid source->ZIP roundtrip is compiled and executed in macOS CI (Objective-C).
On Windows, Python deliberately tests only the verifier's failure boundary.
"""
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

from crane_native_collector_verify import InvalidNativeFixture, verify_collector_fixture

ROOT = Path(__file__).resolve().parents[2]
MARKER = b"CRANE_DISPOSABLE_FIXTURE_V1\n"


class CollectorVerifierTest(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(prefix="crane-n4-fake-")
        self.addCleanup(t.cleanup)
        self.root = Path(t.name)
        (self.root / ".crane-disposable-fixture").write_bytes(MARKER)
        (self.root / "output").mkdir()
        (self.root / "source" / "com.example.crane.native").mkdir(parents=True)

    def test_missing_archive_is_rejected(self):
        with self.assertRaises(InvalidNativeFixture):
            verify_collector_fixture(self.root)

    def test_wrong_root_marker_is_rejected(self):
        (self.root / ".crane-disposable-fixture").write_bytes(b"NOT-A-FIXTURE")
        with self.assertRaises(InvalidNativeFixture):
            verify_collector_fixture(self.root)

    def test_arbitrary_valid_zip_cannot_be_mistaken_for_n4_fixture(self):
        target = self.root / "output" / "native-single.cranect"
        with zipfile.ZipFile(target, "w") as archive:
            archive.writestr("Info.plist", b"not-a-real-Info")
        with self.assertRaises(InvalidNativeFixture):
            verify_collector_fixture(self.root)

    def test_symlink_source_is_rejected(self):
        app = self.root / "source" / "com.example.crane.native"
        # Test only a marker case and do not depend on symlink privileges on Windows.
        link = self.root / "source" / "linked-other-source"
        try:
            link.symlink_to(app, target_is_directory=True)
        except (OSError, NotImplementedError) as e:
            self.skipTest(str(e))
        target = self.root / "output" / "native-single.cranect"
        target.write_bytes(b"bad")
        with self.assertRaises(InvalidNativeFixture):
            verify_collector_fixture(link)

    def test_cli_returns_fixed_status_without_disclosing_fixture_root(self):
        cli = ROOT / "reconstruction/tools/crane_native_collector_verify.py"
        proc = subprocess.run(
            [sys.executable, str(cli), "--fixture-root", str(self.root)],
            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)
        self.assertIn('"status": "native_disposable_source_fixture_rejected"',
                      proc.stdout)
        self.assertNotIn(str(self.root), proc.stdout + proc.stderr)

    def test_scanner_export_is_disposable_and_no_arbitrary_path_parameter(self):
        header = (ROOT / "reconstruction/sources/prefs/"
                  "CRBackupNativeFixtureCollector.h").read_text(encoding="utf8")
        impl = (ROOT / "reconstruction/sources/prefs/"
                "CRBackupNativeFixtureCollector.m").read_text(encoding="utf8")
        self.assertIn("writeDisposableSourceBackupAtRoot:", header)
        self.assertNotIn("containerPath:", header)
        self.assertIn('openat(top, "source"', impl)
        self.assertIn('CN4App = @"com.example.crane.native"', impl)
        self.assertIn("AT_SYMLINK_NOFOLLOW", impl)
        self.assertIn("expected->st_nlink != 1", impl)
        self.assertIn("openat(parent, name, flags)", impl)
        self.assertNotIn("SecItemCopyMatching", impl)

    def test_metadata_does_not_invent_hidden_or_user_identity(self):
        impl = (ROOT / "reconstruction/sources/prefs/"
                "CRBackupNativeFixtureCollector.m").read_text(encoding="utf8")
        self.assertIn("getpwuid_r(", impl)
        self.assertIn("getgrgid_r(", impl)
        self.assertIn("NSFileCreationDate", impl)
        self.assertIn("NSFileModificationDate", impl)
        self.assertNotIn("NSFileExtensionHidden:", impl)


if __name__ == "__main__":
    unittest.main()
