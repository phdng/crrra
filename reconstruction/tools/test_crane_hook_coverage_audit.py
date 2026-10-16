"""G-09 hook-source audit: deterministic row-level provenance and safe claims."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "reconstruction/tools/crane_hook_coverage_audit.py"
spec = importlib.util.spec_from_file_location("crane_hook_coverage_audit", SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class HookCoverageAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = audit.build()

    def test_159_rows_preserved_with_binary_origins_and_source_status(self):
        rows = self.report["rows"]
        self.assertEqual(len(rows), 159)
        self.assertEqual([r["ordinal"] for r in rows], list(range(1, 160)))
        self.assertEqual(self.report["by_binary"], {
            "CraneSB.dylib": 113, "CraneSupport.dylib": 45, "CranePrefs": 1,
        })
        self.assertEqual(sum(self.report["source_match_counts"].values()), 159)
        for row in rows:
            self.assertTrue(row["original"]["target_selector"])
            self.assertTrue(row["original"]["registration_address"])
            self.assertFalse(row["runtime_verified"])
            self.assertFalse(row["behavior_verified"])

    def test_0xcbec_original_class_attribution_is_not_claimed(self):
        items = [r for r in self.report["rows"]
                 if r["original"]["registering_function"] == "_initNotificationSupport"]
        self.assertEqual(len(items), 52)
        self.assertTrue(all(r["original_class_attribution"] ==
                            "alias_collapsed_unverified" for r in items))

    def test_duplicate_original_selectors_are_retained_not_conflated(self):
        duplicates = [r for r in self.report["rows"]
                      if r["original_same_selector_api_count"] > 1]
        self.assertGreater(len(duplicates), 0)
        for row in duplicates:
            self.assertIn(row["source_match_status"],
                          {"ambiguous_original_duplicate", "no_installer_candidate"})
        self.assertEqual(sum(1 for r in self.report["rows"] if
                             r["original"]["target_selector"] ==
                             "requestTokenForRemoteNotificationsForBundleIdentifier:withCompletionHandler:"
                             and r["original"]["registering_function"] ==
                             "_initNotificationSupport"), 2)

    def test_generator_matches_committed_json_byte_for_byte(self):
        expected = (json.dumps(self.report, ensure_ascii=False, sort_keys=True,
                               indent=2) + "\n").encode("utf-8")
        self.assertEqual(audit.MATRIX.read_bytes(), expected)

    def test_scanner_ignores_comments_and_requires_a_registration(self):
        source = (
            "// MSHookMessageEx(cls, sel, (IMP)fake, &orig);\n"
            "/* SEL decoy = NSSelectorFromString(@\"commentOnly:\"); */\n"
            "SEL realSEL = NSSelectorFromString(@\"actualHook:\");\n"
            "MSHookMessageEx(cls, realSEL, (IMP)RealHook, &original);\n"
            "SEL unusedSEL = NSSelectorFromString(@\"noInstall:\");\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "mock.m"
            path.write_text(source, encoding="utf-8")
            with patch.object(audit, "REPO", Path(tmp)):
                found = audit._registrations("mock.m")
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["selector"], "actualHook:")
        self.assertEqual(found[0]["api"], "MSHookMessageEx")
        self.assertEqual(found[0]["impl_expression"], "(IMP)RealHook")

    def test_scanner_recovers_class_add_method_and_balanced_arguments(self):
        source = (
            "class_addMethod(cls, NSSelectorFromString(@\"added:\") ,"
            " (IMP)NewHook, \"v@:@\");\n"
            "MSHookMessageEx(cls, @selector(setEnabled:), (IMP)ChangeHook, &orig);\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "mock.m").write_text(source, encoding="utf-8")
            with patch.object(audit, "REPO", Path(tmp)):
                found = audit._registrations("mock.m")
        self.assertEqual([(item["api"], item["selector"]) for item in found], [
            ("class_addMethod", "added:"),
            ("MSHookMessageEx", "setEnabled:"),
        ])

    def test_test_references_are_text_only_not_runtime_evidence(self):
        for row in self.report["rows"]:
            selector = row["original"]["target_selector"]
            mentions = row["test_source_selector_mentions_only"]
            self.assertEqual(mentions, sorted(set(mentions)))
            self.assertFalse(row["runtime_verified"])
            self.assertFalse(row["behavior_verified"])
            for path in mentions:
                self.assertNotEqual(Path(path).name, "test_crane_hook_coverage_audit.py")
                self.assertIn(selector, (REPO / path).read_text(encoding="utf-8"))
        self.assertIn("textual only", self.report["interpretation"])

    def test_all_source_evidence_has_concrete_tracked_line(self):
        for row in self.report["rows"]:
            for item in row["source_candidates"]:
                source = REPO / item["file"]
                self.assertTrue(source.exists())
                self.assertGreater(item["line"], 0)
                self.assertLessEqual(item["line"],
                                     len(source.read_text(encoding="utf-8").splitlines()))
                self.assertEqual(item["selector"], row["original"]["target_selector"])
                self.assertEqual(item["api"], row["original"]["hook_api"])

    def test_summary_never_calls_textual_evidence_runtime_parity(self):
        self.assertEqual(self.report["schema"], "crane_hook_source_audit_v1")
        self.assertIn("not proof", self.report["interpretation"])
        for row in self.report["rows"]:
            self.assertNotIn("implemented", row["source_match_status"])
            self.assertNotIn("verified", row["source_match_status"])


if __name__ == "__main__":
    unittest.main()
