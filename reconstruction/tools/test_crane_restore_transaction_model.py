"""G-11 D1 purely virtual fault injection and rollback contract tests.

Only synthetic disposable ZIP files and test inventories are created. Running
the simulator must NEVER modify them or actually restore any container.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import crane_backup_fixture_writer as writer
from crane_restore_preflight import preflight
from crane_restore_transaction_model import (
    FAILPOINTS, SimulationError, simulate_transaction,
)

APP1 = "com.example.crane-virtual-one"
APP2 = "org.example.crane-virtual-two"
GROUP = "group.com.example.crane-virtual"
SRC1 = "1A3B6158-214A-4DE1-93DF-9C6BA3A4D0A1"
SRC2 = "4F2B8158-96EB-4EA1-8832-127F92281F93"
DST1 = "8B0BEFC0-6675-40B2-9B74-A29363E23006"
DST2 = "53D6A6A4-94A7-4983-B185-9AB80DDF2FC4"
PRIVATE = "NEVER_LOG_USER_IDENTIFIER"


def record(app: str, cid: str):
    return {
        "applicationIdentifier": app,
        "containerIdentifier": cid,
        "containerName": PRIVATE,
        "originalPaths": {
            app: "/private/var/mobile/Disposable/" + PRIVATE,
            GROUP: "/private/var/mobile/Shared/" + PRIVATE,
        },
        "sourceDirectories": {app: "test/app", GROUP: "test/group"},
    }


def target(app: str, cid: str, *, active: bool = False, existing: bool = False):
    return {
        "applicationIdentifier": app,
        "containerIdentifier": cid,
        "defaultAssociatedIdentifiers": [app, GROUP],
        "targetAssociatedIdentifiers": [app, GROUP],
        "active": active, "existingData": existing,
    }


def mapping(app: str, source: str, destination: str):
    return {
        "sourceApplicationIdentifier": app,
        "sourceContainerIdentifier": source,
        "targetApplicationIdentifier": app,
        "targetContainerIdentifier": destination,
    }


class RestoreTransactionModelTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="crane-transaction-model-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / writer.MARKER).write_bytes(writer.MARKER_CONTENT)
        (self.root / "test/app").mkdir(parents=True)
        (self.root / "test/group").mkdir(parents=True)
        (self.root / "output").mkdir()
        (self.root / "test/app/placeholder.txt").write_text("NOT_REAL_APP_DATA")
        (self.root / "test/group/placeholder.txt").write_text("NOT_REAL_GROUP")
        self.inventory = self.root / "inventory.json"
        self.archive = self.create("single.cranect",
                                   [record(APP1, SRC1)])
        self.set_inventory([target(APP1, DST1)],
                           [mapping(APP1, SRC1, DST1)])

    def create(self, filename: str, rows: list[dict]) -> Path:
        (self.root / "manifest.json").write_text(
            json.dumps({"containers": rows}), encoding="utf8")
        writer.write_fixture(self.root, manifest_name="manifest.json",
                             output_name=filename)
        return self.root / "output" / filename

    def set_inventory(self, targets: list[dict], mappings: list[dict],
                      free: int | None = 10**9):
        self.inventory.write_text(json.dumps({
            "targets": targets, "mappings": mappings, "freeBytes": free,
        }), encoding="utf8")

    def multi(self) -> Path:
        archive = self.create(
            "multi.cranebk",
            [record(APP1, SRC1), record(APP2, SRC2)],
        )
        self.set_inventory(
            [target(APP1, DST1), target(APP2, DST2)],
            [mapping(APP1, SRC1, DST1), mapping(APP2, SRC2, DST2)],
        )
        return archive

    def assert_no_real_action(self, report: dict):
        for name in (
            "restore_executable", "real_rollback_implemented",
            "device_data_touched", "filesystem_writes", "zip_extracted",
            "keychain_contents_read", "original_compatibility_proven",
        ):
            self.assertIs(report[name], False, name)
        serialized = json.dumps(report, sort_keys=True)
        for secret in (APP1, APP2, GROUP, SRC1, SRC2, DST1, DST2,
                       PRIVATE, "/private/var/mobile/"):
            self.assertNotIn(secret, serialized)

    def test_success_single_is_virtual_commit_only(self):
        before = self.archive.read_bytes()
        inventory_before = self.inventory.read_bytes()
        outcome = simulate_transaction(preflight(self.archive, self.inventory))
        self.assertEqual(outcome["status"],
                         "simulation_committed_virtual_only")
        self.assertTrue(outcome["simulated_snapshot_verified"])
        self.assertTrue(outcome["simulated_atomicity_pass"])
        self.assertFalse(outcome["simulated_rollback_verified"])
        self.assertEqual(outcome["simulated_targets"], 1)
        self.assert_no_real_action(outcome)
        self.assertEqual(self.archive.read_bytes(), before)
        self.assertEqual(self.inventory.read_bytes(), inventory_before)

    def test_success_multi_simulates_single_commit_boundary(self):
        archive = self.multi()
        report = simulate_transaction(preflight(archive, self.inventory))
        self.assertEqual(report["status"], "simulation_committed_virtual_only")
        self.assertEqual(report["simulated_targets"], 2)
        self.assertEqual(report["simulated_transitions"].count("simulated_commit"), 1)
        self.assert_no_real_action(report)

    def test_faults_single_each_revert_snapshot(self):
        checked = preflight(self.archive, self.inventory)
        for failpoint in FAILPOINTS:
            with self.subTest(failpoint=failpoint):
                outcome = simulate_transaction(
                    checked, inject_failure=failpoint)
                self.assertEqual(outcome["status"],
                                 "simulation_rolled_back_virtual_only")
                self.assertTrue(outcome["simulated_rollback_verified"])
                self.assertTrue(outcome["simulated_atomicity_pass"])
                self.assertTrue(outcome["failure_injected"])
                self.assertIn("simulated_rollback", outcome["simulated_transitions"])
                self.assertNotIn("simulated_commit", outcome["simulated_transitions"])
                self.assert_no_real_action(outcome)

    def test_faults_multi_revert_all_virtual_targets(self):
        archive = self.multi()
        checked = preflight(archive, self.inventory)
        before = archive.read_bytes(), self.inventory.read_bytes()
        for failpoint in FAILPOINTS:
            with self.subTest(failpoint=failpoint):
                outcome = simulate_transaction(
                    checked, inject_failure=failpoint)
                self.assertEqual(outcome["status"],
                                 "simulation_rolled_back_virtual_only")
                self.assertEqual(outcome["simulated_targets"], 2)
                self.assertTrue(outcome["simulated_rollback_verified"])
                self.assert_no_real_action(outcome)
                self.assertEqual(
                    (archive.read_bytes(), self.inventory.read_bytes()), before)

    def test_multi_partial_promotion_always_rolled_back(self):
        checked = preflight(self.multi(), self.inventory)
        outcome = simulate_transaction(
            checked, inject_failure="after_first_promotion")
        self.assertEqual(outcome["simulated_transitions"], [
            "after_snapshot", "after_staging", "after_first_promotion",
            "simulated_rollback",
        ])
        self.assertTrue(outcome["simulated_rollback_verified"])

    def test_blocked_preflight_never_even_simulates(self):
        self.set_inventory([target(APP1, DST1, existing=True)],
                           [mapping(APP1, SRC1, DST1)])
        checked = preflight(self.archive, self.inventory)
        self.assertEqual(checked["status"], "preflight_blocked")
        report = simulate_transaction(checked)
        self.assertEqual(report["status"], "simulation_not_run_blocked")
        self.assertFalse(report["simulated_atomicity_pass"])
        self.assertEqual(report["simulated_transitions"], [])
        self.assert_no_real_action(report)

    def test_unknown_free_space_never_simulates(self):
        self.set_inventory([target(APP1, DST1)],
                           [mapping(APP1, SRC1, DST1)], free=None)
        report = simulate_transaction(preflight(self.archive, self.inventory))
        self.assertEqual(report["status"], "simulation_not_run_blocked")
        self.assertFalse(report["simulated_atomicity_pass"])

    def test_malformed_or_forged_preflight_denied(self):
        checked = preflight(self.archive, self.inventory)
        for key in ("restore_executable", "inventory_verified_against_device",
                    "rollback_implemented", "wrote_files",
                    "payload_crc_verified", "keychain_contents_read"):
            with self.subTest(field=key):
                forged = dict(checked)
                forged[key] = True
                with self.assertRaises(SimulationError):
                    simulate_transaction(forged)
        forged = dict(checked)
        forged["mapping_count"] = 2
        with self.assertRaises(SimulationError):
            simulate_transaction(forged)

    def test_unknown_faultpoint_denied(self):
        checked = preflight(self.archive, self.inventory)
        with self.assertRaises(SimulationError):
            simulate_transaction(checked, inject_failure="after_disk_wipe")

    def test_cli_success_and_injected_fail_both_non_executable(self):
        cli = Path(__file__).with_name("crane_restore_transaction_model.py")
        argv = [sys.executable, str(cli), "--archive", str(self.archive),
                "--inventory", str(self.inventory)]
        ok = subprocess.run(argv, capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertEqual(json.loads(ok.stdout)["status"],
                         "simulation_committed_virtual_only")
        failed = subprocess.run(
            argv + ["--inject-failure", "after_first_promotion"],
            capture_output=True, text=True)
        self.assertEqual(failed.returncode, 0, failed.stderr)
        self.assertEqual(json.loads(failed.stdout)["status"],
                         "simulation_rolled_back_virtual_only")
        self.assertNotIn(PRIVATE, ok.stdout)
        self.assertNotIn(APP1, failed.stdout)

    def test_cli_blocked_and_invalid_are_redacted(self):
        cli = Path(__file__).with_name("crane_restore_transaction_model.py")
        args = [sys.executable, str(cli), "--archive", str(self.archive),
                "--inventory", str(self.inventory)]
        self.set_inventory([target(APP1, DST1, active=True)],
                           [mapping(APP1, SRC1, DST1)])
        blocked = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(blocked.returncode, 1)
        self.assertEqual(json.loads(blocked.stdout)["status"],
                         "simulation_not_run_blocked")
        self.inventory.write_text("{invalid " + PRIVATE)
        invalid = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(invalid.returncode, 2)
        self.assertEqual(json.loads(invalid.stdout)["status"],
                         "simulation_unavailable_or_invalid")
        self.assertNotIn(PRIVATE, invalid.stdout)
        self.assertNotIn(PRIVATE, invalid.stderr)


if __name__ == "__main__":
    unittest.main()
