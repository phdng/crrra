"""G-11 N6: real CraneManager singleton adapter must remain explicit/read-only."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREF = ROOT / "reconstruction/sources/prefs"
TOOL = ROOT / "reconstruction/tools"


class NativeManagerBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = (PREF / "CRBackupNativeManagerPreflight.h").read_text(encoding="utf8")
        cls.source = (PREF / "CRBackupNativeManagerPreflight.m").read_text(encoding="utf8")
        cls.smoke = (TOOL / "native_backup_manager_bridge_smoke.m").read_text(encoding="utf8")
        cls.manager_header = (ROOT / "reconstruction/sources/common/CRManager.h").read_text(encoding="utf8")

    def test_real_runtime_lookup_only_when_explicitly_called(self):
        self.assertIn("probeRegisteredApplication:", self.header)
        self.assertIn('NSClassFromString(@"CraneManager")', self.source)
        self.assertIn("SEL sharedSEL = @selector(sharedManager)", self.source)
        self.assertIn("objc_msgSend)(managerClass, sharedSEL)", self.source)
        self.assertNotIn("+ (void)load", self.source)
        self.assertNotIn("+ (void)initialize", self.source)

    def test_selector_provenance_matches_existing_manager(self):
        for selector in (
            "isApplicationSupportedByCrane:",
            "containerIdentifiersOfApplicationWithIdentifier:",
            "pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:",
        ):
            with self.subTest(selector=selector):
                self.assertIn(selector, self.source)
                self.assertIn(selector.split(":")[0], self.manager_header)

    def test_adapter_delegates_full_validation_to_n5_only(self):
        self.assertIn("CRBackupNativeSourcePreflight", self.source)
        self.assertIn("resolver:(id<CRBackupSourceResolver>)manager", self.source)
        for guard in (
            '[report[@"backupReady"] isEqual:@NO]',
            '[report[@"restoreExecutable"] isEqual:@NO]',
            '[report[@"sourceContentsRead"] isEqual:@NO]',
            '[report[@"keychainContentsRead"] isEqual:@NO]',
        ):
            self.assertIn(guard, self.source)

    def test_errors_are_fixed_and_redacted(self):
        self.assertIn(
            '@"Crane read-only manager source preflight unavailable"', self.source)
        self.assertIn("CR6Fail(error, 4)", self.source)
        self.assertNotIn("inner.localizedDescription", self.source)
        self.assertNotIn("NSLog(", self.source)

    def test_no_mutating_selector_in_adapter(self):
        for prohibited in (
            "setActiveContainerIdentifier:", "createNewContainer",
            "wipeContainer", "moveOrCopyContainer",
            "reloadApplicationWithIdentifier:",
            "dumpKeychain", "restoreKeychain", "SecItem",
            "readdir(", "read(", "write(", "open(",
            "NSFileManager", "CraneManager sharedManager]",
        ):
            with self.subTest(prohibited=prohibited):
                self.assertNotIn(prohibited, self.source)

    def test_mock_compiles_real_adapter_without_real_library(self):
        self.assertIn('objc_allocateClassPair([NSObject class], "CraneManager", 0)',
                      self.smoke)
        self.assertIn("objc_registerClassPair(cls)", self.smoke)
        self.assertIn("gReadCalls == 3", self.smoke)
        self.assertIn("gReadCalls == before + 3", self.smoke)
        for code in ("1", "3", "4"):
            self.assertIn(f", {code});", self.smoke)

    def test_real_ui_not_enabled(self):
        prefs = (PREF / "CRPreferences.m").read_text(encoding="utf8")
        self.assertNotIn("probeRegisteredApplication:", prefs)
        self.assertIn(
            '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"]', prefs)
        self.assertIn(
            '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]', prefs)


if __name__ == "__main__":
    unittest.main()
