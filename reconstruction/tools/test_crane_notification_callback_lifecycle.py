"""G-09 notification callback/foreground source contract, not a runtime test.

CI must use tracked provenance excerpts: full original CraneSB IDA exports
under gitignored Library/ exist only on the development workstation.
"""
import json
from pathlib import Path
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "reconstruction/sources/cranesb/CRBadgeStore.m"
EVIDENCE = (REPO / "reconstruction/tools/fixtures/"
            "cranesb_notification_callback_lifecycle_evidence.json")


def function_slice(source, name, end_name):
    return source.split(name, 1)[1].split(end_name, 1)[0]


class NotificationCallbackLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.fixture = json.loads(EVIDENCE.read_text(encoding="utf-8"))

    def test_tracked_original_evidence_and_optional_local_decompile(self):
        self.assertEqual(self.fixture["schema"],
                         "cranesb_notification_callback_lifecycle_source_v1")
        self.assertIn("not_runtime_parity", self.fixture["claim"])
        self.assertEqual(
            {record["address"] for record in self.fixture["original"]},
            {"0x11420", "0x126d0", "0xf254", "0x10218", "0x11fb0"})
        for record in self.fixture["original"]:
            path = REPO / record["path"]
            self.assertTrue(record["markers"])
            self.assertTrue(record["path"].startswith(
                "Library/MobileSubstrate/DynamicLibraries/"
                "CraneSB.dylib_export_for_ai/decompile/"))
            if path.is_file():
                original = path.read_text(encoding="utf-8")
                for marker in record["markers"]:
                    with self.subTest(file=record["path"], marker=marker):
                        self.assertIn(marker, original)

    def test_bulletin_action_special_cases_forward_original_once(self):
        action = function_slice(
            self.source,
            "static void CRBadgeBulletinAction(id self, SEL cmd, id response, id completion)",
            "static id CRBadgeSourceMarkerFromInfo(id info);")
        self.assertIn("if (!original)\n        return;", action)
        self.assertIn("if (actionType == 8 || actionType == 5) {", action)
        self.assertIn("original(self, cmd, response, completion);\n        return;",
                      action)
        self.assertIn("if (!container) {\n        original(self, cmd, response, completion);",
                      action)
        self.assertIn("id container = CRBadgeContainerForNotificationInfo(context, appID);",
                      action)

    def test_bulletin_switch_precedes_action_forwarding_callback(self):
        action = function_slice(
            self.source,
            "static void CRBadgeBulletinAction(id self, SEL cmd, id response, id completion)",
            "static id CRBadgeSourceMarkerFromInfo(id info);")
        self.assertIn("setActiveContainerIdentifier:container", action)
        self.assertIn("forApplicationWithIdentifier:appID", action)
        self.assertIn("reloadApplication:YES", action)
        self.assertIn("usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {",
                      action)
        self.assertIn("(void)authenticated;", action)
        self.assertIn("original(self, cmd, response, completion);", action.split(
            "usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {", 1
        )[1])
        before_callback = action.split(
            "usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {", 1
        )[0]
        # Earlier fast-path forwarding is expected; the asynchronous
        # switch path must not forward before its success handler runs.
        switch_start = before_callback.index("[[CraneManager sharedManager]")
        self.assertNotIn("original(self, cmd, response, completion);",
                         before_callback[switch_start:])
        self.assertEqual(
            action.count("usingBiometricsIfNeededWithSuccessHandler:"), 1)

    def test_foreground_context_set_before_original_and_queue_cleanup(self):
        outer = function_slice(
            self.source, "static void CRBadgeOuterSave(", "static NSString *CRBadgeSourceForRecord(")
        self.assertIn("gCRBadgeForegroundContainer = [container copy];", outer)
        self.assertIn("foregroundGeneration = ++gCRBadgeForegroundGeneration;",
                      outer)
        self.assertLess(outer.index("gCRBadgeForegroundContainer = [container copy];"),
                        outer.index("original(self, cmd, record, repost, appID, completion);"))
        self.assertIn("} @finally {", outer)
        self.assertIn("if (foregroundGeneration == gCRBadgeForegroundGeneration)",
                      outer)
        self.assertIn("dispatch_async(queue, clearForeground);", outer)
        self.assertIn("else\n            clearForeground();", outer)
        foreground = function_slice(
            self.source,
            "static BOOL CRBadgeSystemForeground(id self, SEL cmd, NSString *appID)",
            "/* CraneSB 0xBA6C:")
        self.assertIn("BOOL foreground = original ? original(self, cmd, appID) : NO;",
                      foreground)
        self.assertIn("if (!foreground || !foregroundContainer)", foreground)
        self.assertIn('NSClassFromString(@"FBProcessManager")', foreground)
        self.assertIn("return [foregroundContainer isEqualToString:active];", foreground)

    def test_no_full_decompile_required_in_clean_ci_checkout(self):
        # Do not merely skip all tests if the original exports are absent.
        # Assert the mandatory fixture/current-source regression still runs.
        original_paths = {
            (REPO / record["path"]).resolve()
            for record in self.fixture["original"]
        }
        real_is_file = Path.is_file

        def simulated_is_file(path):
            if path.resolve() in original_paths:
                return False
            return real_is_file(path)

        with patch.object(Path, "is_file", simulated_is_file):
            self.test_tracked_original_evidence_and_optional_local_decompile()
            self.test_bulletin_switch_precedes_action_forwarding_callback()
            self.test_foreground_context_set_before_original_and_queue_cleanup()


if __name__ == "__main__":
    unittest.main()
