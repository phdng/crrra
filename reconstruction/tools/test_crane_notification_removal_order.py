"""Native G-09 notification removal enumeration parity (source contract only).

The original IDA C export lives in gitignored Library/; a small tracked,
source-linked fixture makes the same invariant testable in clean CI.
These tests DO NOT run iOS hooks or prove callback timing on device.
"""
import json
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[2]
EVIDENCE = REPO / "reconstruction/tools/fixtures/cranesb_pending_removal_order_evidence.json"
SOURCE = REPO / "reconstruction/sources/cranesb/CRBadgeStore.m"


def explicit_order(requested, pending):
    """Independent pure-Python model of the recovered C1D4 iteration."""
    return [identifier for identifier in requested if identifier in pending]


def all_order(pending):
    """Independent model of C5E0: pending list order is kept."""
    return list(pending)


class NotificationRemovalOrderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads(EVIDENCE.read_text(encoding="utf-8"))
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.resolver = cls.source.split(
            "static void CRBadgeResolveRemovalIdentifiers(", 1
        )[1].split("static IMP gCRBadgeRemovePendingWithReplyOriginal;", 1)[0]

    def test_tracked_evidence_has_explicit_original_provenance(self):
        fixture = self.fixture
        self.assertEqual(fixture["schema"],
                         "crane_pending_notification_removal_order_v1")
        self.assertIn("not_runtime_parity", fixture["scope"])
        for kind, name, address in (
            ("original_explicit", "sub_C1D4", "0xc1d4"),
            ("original_all", "sub_C5E0", "0xc5e0"),
        ):
            record = fixture[kind]
            self.assertEqual(record["function"], name)
            self.assertEqual(record["address"], address)
            self.assertTrue(record["source"].endswith(
                name.removeprefix("sub_") + ".c"))
            # Optional workstation provenance cross-check; Library/ is
            # gitignored and MUST NOT be required in GitHub Actions.
            original_path = REPO / record["source"]
            if original_path.is_file():
                original = original_path.read_text(encoding="utf-8")
                for field, excerpt in record.items():
                    if field not in ("source", "function", "address"):
                        with self.subTest(original=name, field=field):
                            self.assertIn(excerpt, original)

    def test_current_explicit_removal_iterates_requested_then_pending(self):
        resolver = self.resolver
        explicit = resolver.split("} else {", 1)[1]
        request_for = explicit.index("for (id requestedIdentifier in requested)")
        pending_for = explicit.index("for (id request in pending)")
        compare = explicit.index("[identifier isEqualToString:requestedIdentifier]")
        append = explicit.index("[identifiers addObject:requestedIdentifier]")
        stop = explicit.index("break;", append)
        self.assertLess(request_for, pending_for)
        self.assertLess(pending_for, compare)
        self.assertLess(compare, append)
        self.assertLess(append, stop)
        self.assertNotIn("[requested containsObject:identifier]", resolver)
        self.assertNotIn("[identifiers addObject:identifier]", explicit)

    def test_remove_all_keeps_pending_iteration_and_scoped_resolver(self):
        resolver = self.resolver
        pending_all = resolver.split("if (removeAll) {", 1)[1].split(
            "} else {", 1
        )[0]
        self.assertIn("for (id request in pending)", pending_all)
        self.assertIn("[identifiers addObject:identifier]", pending_all)
        self.assertIn("CRBadgeRedirectionEnabled(appID)", resolver)
        self.assertIn("[NSXPCConnection currentConnection]", resolver)
        self.assertIn("reply(@[])", resolver)
        self.assertIn("reply([identifiers copy])", resolver)

    def test_original_order_examples_preserve_duplicates_and_filter_absent(self):
        for example in self.fixture["examples"]:
            with self.subTest(example=example):
                self.assertEqual(explicit_order(example["requested"], example["pending"]),
                                 example["explicit"])
                self.assertEqual(all_order(example["pending"]), example["all"])
        example = self.fixture["examples"][0]
        # Guard against the prior implementation, which used pending order,
        # losing a repeated requested identifier in the callback argument.
        prior = [item for item in example["pending"] if item in example["requested"]]
        self.assertNotEqual(prior, example["explicit"])


if __name__ == "__main__":
    unittest.main()
