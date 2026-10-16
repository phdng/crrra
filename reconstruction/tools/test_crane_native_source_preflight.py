"""G-11 N5 native source-map preflight: static safety and independent test vectors.

Positive macOS Foundation smoke exercises an in-memory resolver with fake
OS-temp roots. This Python test does not read actual device container paths.
"""
from __future__ import annotations

from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[2]


class NativeSourcePreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native = (REPO / "reconstruction/sources/prefs/"
                      "CRBackupNativeSourcePreflight.m").read_text(encoding="utf8")
        cls.header = (REPO / "reconstruction/sources/prefs/"
                      "CRBackupNativeSourcePreflight.h").read_text(encoding="utf8")
        cls.smoke = (REPO / "reconstruction/tools/"
                     "native_backup_source_preflight_smoke.m").read_text(encoding="utf8")

    def test_resolver_selectors_exactly_match_original_manager_api(self):
        manager = (REPO / "reconstruction/sources/common/"
                   "CRManager.h").read_text(encoding="utf8")
        selectors = [
            "isApplicationSupportedByCrane:",
            "containerIdentifiersOfApplicationWithIdentifier:",
            "pathsAssociatedToContainerWithIdentifier:",
            "ofApplicationWithIdentifier:",
        ]
        for selector in selectors:
            with self.subTest(selector=selector):
                self.assertIn(selector, manager)
                self.assertIn(selector, self.header)
        self.assertIn("@protocol CRBackupSourceResolver", self.header)

    def test_source_root_path_gate_must_be_read_only(self):
        for expected in (
            "#if TARGET_OS_IPHONE",
            '"/private/var/mobile/Containers/"',
            "NSTemporaryDirectory().fileSystemRepresentation",
            "realpath(", "lstat(", "fstat(", "open(",
            "S_ISDIR(", "O_NOFOLLOW", "CR5CanonicalAllowed(resolved)",
            "CR5Ancestor(existing, canonical)",
            "CR5Ancestor(canonical, existing)",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, self.native)
        for forbidden in (
            "readdir(", "fstatat(", "read(", "write(",
            "NSFileManager", "SecItemCopyMatching", "SecItemDelete",
            "unlink(", "chown(", "chmod(", "rename(",
            "CraneManager.sharedManager", "opainject",
        ):
            self.assertNotIn(forbidden, self.native)

    def test_preflight_must_not_grant_permission_to_backup_or_restore(self):
        for marker in (
            '@"backupReady":@NO',
            '@"restoreExecutable":@NO',
            '@"sourceFilesEnumerated":@NO',
            '@"sourceContentsRead":@NO',
            '@"keychainContentsRead":@NO',
        ):
            self.assertIn(marker, self.native)
        self.assertNotIn("originalPaths", self.native)
        self.assertNotIn('@"path":', self.native)

    def test_resolver_cannot_supply_unsupported_application_or_container(self):
        self.assertIn("[resolver isApplicationSupportedByCrane:applicationID]",
                      self.native)
        self.assertIn("[registered containsObject:containerID]", self.native)
        self.assertIn('![containerID isEqualToString:@"DEFAULT"]',
                      self.native)
        self.assertIn("mapping[applicationID]", self.native)
        self.assertIn("mapping.count > CR5MaxRoots", self.native)

    def test_native_smoke_rejects_ambiguity_symlink_and_invalid_source(self):
        for marker in (
            "ExpectError(resolver, App, Container, 7);",
            "ExpectError(resolver, App, Container, 8);",
            "ExpectError(resolver, App, Container, 6);",
            "ExpectError(resolver, App, Container, 5);",
            '@"00000000-0000-4000-8000-000000000999", 3);',
            "ExpectError(resolver, App, Container, 2);",
            "createSymbolicLinkAtPath:alias",
            "sourceFilesEnumerated", "sourceContentsRead",
            "backupReady", "restoreExecutable",
        ):
            self.assertIn(marker, self.smoke)

    def test_no_root_ui_activation(self):
        prefs = (REPO / "reconstruction/sources/prefs/"
                 "CRPreferences.m").read_text(encoding="utf8")
        self.assertNotIn("preflightApplicationIdentifier:", prefs)
        self.assertIn(
            '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]',
            prefs)


if __name__ == "__main__":
    unittest.main()
