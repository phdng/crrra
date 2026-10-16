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

    def test_concatenated_objc_literal_apsd_selectors_are_recovered(self):
        expected = {
            "sendTokenGenerateMessageWithTopicHash:baseToken:appId:expirationTTL:vapidPublicKeyHash:type:onInterface:",
            "_handleMessageMessage:onProtocolConnection:withGeneration:isWakingMessage:fromAgent:",
            "_handleMessageMessage:onInterface:withGeneration:isWakingMessage:fromAgent:",
        }
        actual = {
            row["original"]["target_selector"] for row in self.report["rows"]
            if row["original"]["target_selector"] in expected
            and row["source_match_status"] == "textual_installer_candidate"
            and any(match["file"] == "reconstruction/sources/support/CRApsd.m"
                    for match in row["source_candidates"])
        }
        self.assertEqual(expected, actual)

    def test_scanner_handles_concatenated_literals_and_rejects_computed_names(self):
        source = (
            'SEL joined = NSSelectorFromString(@"doThing:" "forApp:");\n'
            'MSHookMessageEx(cls, joined, (IMP)Combined, &orig);\n'
            'MSHookMessageEx(cls, NSSelectorFromString(@"inline:" "extra:"),'
            ' (IMP)Inline, &orig2);\n'
            'MSHookMessageEx(cls, NSSelectorFromString([NSString'
            ' stringWithFormat:@"%@", @"guess"]), (IMP)Guess, &orig3);\n'
            'MSHookMessageEx(cls, NSSelectorFromString(@"bad\\\\escape:"),'
            ' (IMP)Bad, &orig4);\n'
        )
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "mock.m").write_text(source, encoding="utf-8")
            with patch.object(audit, "REPO", Path(tmp)):
                found = audit._registrations("mock.m")
        self.assertEqual([x["selector"] for x in found],
                         ["doThing:forApp:", "inline:extra:"])

    def test_12_unmatched_sources_are_reviewed_without_parity_assumption(self):
        unknown = [r for r in self.report["rows"]
                   if r["source_match_status"] == "no_installer_candidate"]
        self.assertEqual(len(unknown), 12)
        self.assertEqual(self.report["unmatched_reviewed_alternative_count"], 12)
        self.assertTrue(all(r["reviewed_alternative_not_parity"] is not None
                            for r in unknown))
        for row in unknown:
            evidence = row["reviewed_alternative_not_parity"]
            if evidence:
                self.assertFalse(evidence["equivalence_verified"])
                self.assertGreater(evidence["anchor_occurrences"], 0)
                content = (REPO / evidence["file"]).read_text(encoding="utf-8")
                self.assertIn(evidence["anchor"], content)
                self.assertGreater(evidence["line"], 0)

    def test_local_at_selector_definition_is_not_a_missing_hook(self):
        hook = [row for row in self.report["rows"]
                if row["original"]["binary"] == "CraneSB.dylib"
                and row["original"]["registering_function"] == "sub_14D18"
                and row["original"]["target_selector"] == "init"]
        self.assertEqual(len(hook), 1)
        row = hook[0]
        self.assertEqual(row["source_match_status"], "textual_installer_candidate")
        self.assertEqual(row["source_candidate_count"], 1)
        candidate = row["source_candidates"][0]
        self.assertEqual(candidate["file"],
                         "reconstruction/sources/cranesb/CRMenuHooks.m")
        self.assertEqual(candidate["target_expression"], "controllerClass")
        self.assertEqual(candidate["impl_expression"],
                         "(IMP)CRLegacyForceTouchControllerInit")
        self.assertFalse(row["runtime_verified"])
        self.assertFalse(row["behavior_verified"])

    def test_init_original_and_reconstruction_have_the_same_legacy_intent(self):
        original = (REPO / "Library/MobileSubstrate/DynamicLibraries/"
                    "CraneSB.dylib_export_for_ai/decompile/14D18.c").read_text(
                        encoding="utf-8")
        implementation = (REPO / "Library/MobileSubstrate/DynamicLibraries/"
                          "CraneSB.dylib_export_for_ai/decompile/15204.c").read_text(
                              encoding="utf-8")
        current = (REPO / "reconstruction/sources/cranesb/CRMenuHooks.m").read_text(
            encoding="utf-8")
        for marker in ('objc_getClass("SBUIAppIconForceTouchController")',
                       'MSHookMessageEx(v3, "init", sub_15204, &off_2D410)'):
            self.assertIn(marker, original)
        for marker in ('off_2D410()', '"setCrane_provideContainerOptions:", 0'):
            self.assertIn(marker, implementation)
        for marker in ('Class controllerClass =',
                       'NSClassFromString(@"SBUIAppIconForceTouchController")',
                       'SEL initSelector = @selector(init);',
                       'MSHookMessageEx(controllerClass,',
                       '(IMP)CRLegacyForceTouchControllerInit,',
                       'id result = original ? original(self, _cmd) : self;',
                       'CRDynamicBoolSetter(result,',
                       'NO);'):
            self.assertIn(marker, current)

    def test_legacy_init_installation_keeps_original_cf_version_gate(self):
        original = (REPO / "Library/MobileSubstrate/DynamicLibraries/"
                    "CraneSB.dylib_export_for_ai/decompile/14D18.c").read_text(
                        encoding="utf-8")
        current = (REPO / "reconstruction/sources/cranesb/CRMenuHooks.m").read_text(
            encoding="utf-8")
        self.assertIn("if ( kCFCoreFoundationVersionNumber >= 1665.15 )", original)
        self.assertIn('void CRInitApplicationShortcutHooks(void)', current)
        modern_gate = current[current.index("void CRInitApplicationShortcutHooks(void)"):]
        self.assertIn("if (kCFCoreFoundationVersionNumber < 1665.15) {", modern_gate)
        self.assertIn("CRInitLegacyApplicationShortcutHooks();", modern_gate)
        legacy = current[current.index("static void CRInitLegacyApplicationShortcutHooks(void)"):
                         current.index("void CRInitApplicationShortcutLateHooks(void)")]
        self.assertIn('NSClassFromString(@"SBUIAppIconForceTouchController")', legacy)
        self.assertEqual(legacy.count("(IMP)CRLegacyForceTouchControllerInit,"), 1)
        self.assertIn("instancesRespondToSelector:initSelector", legacy)

    def test_local_selector_parser_ignores_comments_and_nearby_fake_names(self):
        source = (
            '// SEL fake = @selector(faked:);\\n'
            'SEL initialized = @selector(init);\\n'
            'MSHookMessageEx(legacy, initialized, (IMP)HookInit, &original);\\n'
            'SEL delayed = @selector(update:);\\n'
            'MSHookMessageEx(legacy, missing, (IMP)Unknown, &unused);\\n'
            'SEL modern = @selector(realSelector:);\\n'
            'class_addMethod(legacy, modern, (IMP)AddMethod, "v@:@");\\n'
        ).replace('\\n', '\n')
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "mock.m").write_text(source, encoding="utf-8")
            with patch.object(audit, "REPO", Path(tmp)):
                found = audit._registrations("mock.m")
        self.assertEqual([(item["api"], item["selector"]) for item in found], [
            ("MSHookMessageEx", "init"),
            ("class_addMethod", "realSelector:"),
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
