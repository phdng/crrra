"""G-11 N8 static safety tests; macOS smoke exercises native Objective-C."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREF = ROOT / "reconstruction/sources/prefs"
TOOLS = ROOT / "reconstruction/tools"


class DisposableSourceDiagnosticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.code = (PREF / "CRBackupDisposableDiagnostic.m").read_text(encoding="utf8")
        cls.header = (PREF / "CRBackupDisposableDiagnostic.h").read_text(encoding="utf8")
        cls.ui = (PREF / "CRPreferences.m").read_text(encoding="utf8")
        cls.mock = (TOOLS / "native_backup_manager_bridge_smoke.m").read_text(encoding="utf8")

    def test_exact_test_bundle_only(self):
        self.assertIn('CR8FixtureApplicationID = @"com.example.crane.native"', self.code)
        self.assertIn("[applicationID isEqualToString:CR8FixtureApplicationID]", self.code)
        self.assertIn("[[NSUUID alloc] initWithUUIDString:containerID]", self.code)

    def test_user_confirmation_before_any_manager_call(self):
        gate = self.code.index("if (!confirmed ||")
        manager = self.code.index("probeTypedRegisteredApplication:")
        self.assertLess(gate, manager)
        self.assertIn("userConfirmedOnce:(BOOL)confirmed", self.header)

    def test_native_singleton_reads_n7_only(self):
        self.assertIn('#import "CRBackupNativeManagerPreflight.h"', self.code)
        self.assertIn("probeTypedRegisteredApplication:", self.code)
        self.assertNotIn("probeRegisteredApplication:", self.code)

    def test_redacted_report_and_error(self):
        for key in (
            '@"rootCount":report[@"rootCount"]',
            '@"applicationRootCount":report[@"applicationRootCount"]',
            '@"appGroupRootCount":report[@"appGroupRootCount"]',
            '@"plugInKitRootCount":report[@"plugInKitRootCount"]',
            '@"sourceContentsRead":@NO',
            '@"keychainContentsRead":@NO',
            '@"backupReady":@NO',
            '@"restoreExecutable":@NO',
        ):
            self.assertIn(key, self.code)
        self.assertIn("error:NULL", self.code)
        self.assertNotIn('@"paths":', self.code)
        self.assertNotIn('@"applicationIdentifier":', self.code)

    def test_ui_is_manual_and_not_automatic(self):
        self.assertIn("runDisposableSourceDiagnostic", self.ui)
        self.assertIn("setButtonAction:@selector(runDisposableSourceDiagnostic)", self.ui)
        self.assertIn("UIAlertActionStyleCancel handler:nil", self.ui)
        self.assertIn("userConfirmedOnce:YES error:&error", self.ui)
        self.assertIn("isEligibleApplicationIdentifier:self.applicationIdentifier", self.ui)

    def test_ui_revalidates_selection_before_run(self):
        self.assertIn("[strongSelf.applicationIdentifier isEqualToString:appID]", self.ui)
        self.assertIn("[strongSelf.containerIdentifier isEqualToString:containerID]", self.ui)

    def test_negative_path_exercised_in_native_mock(self):
        for marker in (
            "gReadCalls == gatedCalls",
            "userConfirmedOnce:NO error:&diagnosticError",
            'probeApplicationIdentifier:@"com.example.other"',
            'containerIdentifier:@"DEFAULT"',
            "gDuplicate = YES;",
            "diagnostic.count == 10",
        ):
            self.assertIn(marker, self.mock)

    def test_no_live_file_or_state_mutations(self):
        for forbidden in (
            "readdir(", "open(", "fstatat(", "write(", "NSLog(", "SecItem",
            "KeychainItems", "removeItemAtPath:", "setActiveContainer",
            "createNewContainer", "setPreferenceValue:",
        ):
            self.assertNotIn(forbidden, self.code)


if __name__ == "__main__":
    unittest.main()
