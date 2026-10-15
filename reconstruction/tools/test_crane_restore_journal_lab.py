"""Filesystem journal laboratory tests — ONLY synthetic tokens under OS temp.

Do not mistake passing tests for crash-safe native iOS multi-container restore.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import crane_backup_fixture_writer as writer
from crane_restore_journal_lab import (
    FAILPOINTS, InjectedCrash, LabError, LAB_DIR, LAB_MARKER,
    LAB_MARKER_CONTENT, _new, _old, recover_fixture, run_fixture,
)

APP1 = "com.example.crane-journal"
APP2 = "org.example.crane-journal"
GROUP = "group.com.example.crane-journal"
SRC1 = "AAAAAAAA-1111-2222-3333-444444444444"
SRC2 = "BBBBBBBB-1111-2222-3333-444444444444"
DST1 = "CCCCCCCC-1111-2222-3333-444444444444"
DST2 = "DDDDDDDD-1111-2222-3333-444444444444"
PRIVATE = "NOT_REAL_USER_DATA"


def container(app, cid):
    return {
        "applicationIdentifier": app, "containerIdentifier": cid,
        "containerName": PRIVATE,
        "originalPaths": {
            app: "/private/var/mobile/TEST/" + PRIVATE,
            GROUP: "/private/var/mobile/Shared/" + PRIVATE,
        },
        "sourceDirectories": {app: "test/app", GROUP: "test/group"},
    }


def target(app, cid):
    return {
        "applicationIdentifier": app, "containerIdentifier": cid,
        "defaultAssociatedIdentifiers": [app, GROUP],
        "targetAssociatedIdentifiers": [app, GROUP],
        "active": False, "existingData": False,
    }


def mapping(app, source, dest):
    return {
        "sourceApplicationIdentifier": app,
        "sourceContainerIdentifier": source,
        "targetApplicationIdentifier": app,
        "targetContainerIdentifier": dest,
    }


class JournalLabTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="crane-journal-lab-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / writer.MARKER).write_bytes(writer.MARKER_CONTENT)
        self.lab = self.root / LAB_DIR
        self.lab.mkdir()
        (self.lab / LAB_MARKER).write_bytes(LAB_MARKER_CONTENT)
        for name in ("slots", "incoming", "journal"):
            (self.lab / name).mkdir()
        for i in (1, 2):
            (self.lab / "slots" / f"slot-{i}.txt").write_bytes(_old(i))
            (self.lab / "incoming" / f"slot-{i}.txt").write_bytes(_new(i))
        (self.root / "test/app").mkdir(parents=True)
        (self.root / "test/group").mkdir()
        (self.root / "test/app/disposable.txt").write_bytes(b"FIXTURE")
        (self.root / "test/group/disposable.txt").write_bytes(b"GROUP")
        (self.root / "output").mkdir()
        self.archive = self.create_archive(
            "single.cranect", [container(APP1, SRC1)])
        self.inventory = self.root / "inventory.json"
        self.update_inventory([target(APP1, DST1)],
                              [mapping(APP1, SRC1, DST1)])

    def create_archive(self, filename, records):
        (self.root / "manifest.json").write_text(
            json.dumps({"containers": records}), encoding="utf-8")
        writer.write_fixture(self.root, manifest_name="manifest.json",
                             output_name=filename)
        return self.root / "output" / filename

    def update_inventory(self, targets, mappings, free=1000000000):
        self.inventory.write_text(json.dumps({
            "targets": targets, "mappings": mappings, "freeBytes": free,
        }), encoding="utf-8")

    def multiple(self):
        existing = self.root / "output/multi.cranebk"
        if existing.is_file():
            self.archive = existing
        else:
            self.archive = self.create_archive(
                "multi.cranebk", [container(APP1, SRC1), container(APP2, SRC2)])
        self.update_inventory(
            [target(APP1, DST1), target(APP2, DST2)],
            [mapping(APP1, SRC1, DST1), mapping(APP2, SRC2, DST2)])

    def slots(self):
        return tuple((self.lab / "slots" / f"slot-{i}.txt").read_bytes()
                     for i in (1, 2))

    def assert_no_leaks(self, obj):
        serialized = json.dumps(obj)
        for secret in (APP1, APP2, GROUP, SRC1, SRC2, DST1, DST2,
                       PRIVATE, "/private/"):
            self.assertNotIn(secret, serialized)
        self.assertFalse(obj["real_restore_supported"])
        self.assertFalse(obj["real_rollback_implemented"])

    def test_single_commit_only_changes_first_synthetic_token(self):
        old_archive = self.archive.read_bytes()
        old_inventory = self.inventory.read_bytes()
        result = run_fixture(self.root, mapping_count=1)
        self.assertEqual(result["status"], "fixture_committed")
        self.assertEqual(self.slots(), (_new(1), _old(2)))
        self.assertEqual(list((self.lab / "journal").iterdir()), [])
        self.assertEqual(self.archive.read_bytes(), old_archive)
        self.assertEqual(self.inventory.read_bytes(), old_inventory)
        self.assert_no_leaks(result)

    def test_multi_commit_all_tokens_and_clean_journal(self):
        self.multiple()
        outcome = run_fixture(self.root, mapping_count=2)
        self.assertEqual(self.slots(), (_new(1), _new(2)))
        self.assertEqual(list((self.lab / "journal").iterdir()), [])
        self.assert_no_leaks(outcome)

    def test_faults_before_commit_recover_both_slots(self):
        for failpoint in FAILPOINTS[:-1]:
            with self.subTest(failpoint=failpoint):
                self.multiple()
                with self.assertRaises(InjectedCrash):
                    run_fixture(self.root, mapping_count=2,
                                inject_failure=failpoint)
                self.assertTrue((self.lab / "journal/state.json").is_file())
                outcome = recover_fixture(self.root)
                self.assertEqual(outcome["status"], "fixture_rolled_back")
                self.assertEqual(self.slots(), (_old(1), _old(2)))
                self.assertEqual(list((self.lab / "journal").iterdir()), [])
                self.assert_no_leaks(outcome)

    def test_crash_after_commit_record_preserves_new_data(self):
        with self.assertRaises(InjectedCrash):
            run_fixture(self.root, mapping_count=1,
                        inject_failure="after_commit_record")
        recovered = recover_fixture(self.root)
        self.assertEqual(recovered["status"], "fixture_commit_preserved")
        self.assertEqual(self.slots(), (_new(1), _old(2)))
        self.assert_no_leaks(recovered)

    def test_crash_during_recovery_restarts_idempotently(self):
        self.multiple()
        with self.assertRaises(InjectedCrash):
            run_fixture(self.root, mapping_count=2,
                        inject_failure="after_all_swaps")
        # Emulate power loss after the FIRST journal backup was atomically
        # restored but before the second, without erasing the state marker.
        os.replace(self.lab / "journal/backup-1.txt",
                   self.lab / "slots/slot-1.txt")
        self.assertEqual(self.slots(), (_old(1), _new(2)))
        outcome = recover_fixture(self.root)
        self.assertEqual(outcome["status"], "fixture_rolled_back")
        self.assertEqual(self.slots(), (_old(1), _old(2)))
        self.assertEqual(list((self.lab / "journal").iterdir()), [])

    def test_mutated_backup_refuses_recovery_without_touching_targets(self):
        self.multiple()
        with self.assertRaises(InjectedCrash):
            run_fixture(self.root, mapping_count=2,
                        inject_failure="after_first_swap")
        (self.lab / "journal/backup-2.txt").write_bytes(b"EVIL")
        before = self.slots()
        with self.assertRaises(LabError):
            recover_fixture(self.root)
        self.assertEqual(self.slots(), before)

    def test_missing_backup_refuses_rollback_if_target_new(self):
        with self.assertRaises(InjectedCrash):
            run_fixture(self.root, mapping_count=1,
                        inject_failure="after_first_swap")
        (self.lab / "journal/backup-1.txt").unlink()
        before = self.slots()
        with self.assertRaises(LabError):
            recover_fixture(self.root)
        self.assertEqual(self.slots(), before)

    def test_recovery_after_partial_committed_cleanup_is_idempotent(self):
        self.multiple()
        with self.assertRaises(InjectedCrash):
            run_fixture(self.root, mapping_count=2,
                        inject_failure="after_commit_record")
        # Emulate crash during committed cleanup. It is safe to resume
        # deleting already-unneeded backups, but NEVER undo committed slots.
        (self.lab / "journal/backup-1.txt").unlink()
        result = recover_fixture(self.root)
        self.assertEqual(result["status"], "fixture_commit_preserved")
        self.assertEqual(self.slots(), (_new(1), _new(2)))
        self.assertEqual(list((self.lab / "journal").iterdir()), [])

    def test_corrupt_journal_refuses_recovery_without_changing_tokens(self):
        with self.assertRaises(InjectedCrash):
            run_fixture(self.root, mapping_count=1,
                        inject_failure="after_first_swap")
        (self.lab / "journal/state.json").write_text(
            '{"version": 1, "phase": "unrecognized", "count": 1}')
        before = self.slots()
        with self.assertRaises(LabError):
            recover_fixture(self.root)
        self.assertEqual(self.slots(), before)

    def test_unknown_journal_member_rejected_without_mutation(self):
        (self.lab / "journal/unknown.bin").write_bytes(b"NOT_ALLOWED")
        with self.assertRaises(LabError):
            run_fixture(self.root, mapping_count=1)
        self.assertEqual(self.slots(), (_old(1), _old(2)))

    def test_unfinished_state_update_is_fail_closed(self):
        with self.assertRaises(InjectedCrash):
            run_fixture(self.root, mapping_count=1,
                        inject_failure="after_journal")
        (self.lab / "journal/state.json.tmp").write_bytes(b"BROKEN")
        with self.assertRaises(LabError):
            recover_fixture(self.root)
        self.assertEqual(self.slots(), (_old(1), _old(2)))

    def test_uncommitted_orphaned_backup_blocks_new_start(self):
        (self.lab / "journal/backup-1.txt").write_bytes(_old(1))
        with self.assertRaises(LabError):
            run_fixture(self.root, mapping_count=1)
        self.assertEqual(self.slots(), (_old(1), _old(2)))

    def test_unmarked_root_and_lab_marker_refused(self):
        (self.lab / LAB_MARKER).write_bytes(b"WRONG")
        with self.assertRaises(LabError):
            run_fixture(self.root, mapping_count=1)
        self.assertEqual(self.slots(), (_old(1), _old(2)))
        (self.lab / LAB_MARKER).write_bytes(LAB_MARKER_CONTENT)
        (self.root / writer.MARKER).write_bytes(b"WRONG")
        with self.assertRaises(LabError):
            run_fixture(self.root, mapping_count=1)

    def test_symlink_slot_is_rejected(self):
        symlink = self.lab / "slots" / "slot-1.txt"
        try:
            symlink.unlink()
            symlink.symlink_to(self.root / "test/app/disposable.txt")
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlinks unavailable on test OS: {exc}")
        with self.assertRaises(LabError):
            run_fixture(self.root, mapping_count=1)
        self.assertEqual((self.root / "test/app/disposable.txt").read_bytes(),
                         b"FIXTURE")

    def test_unknown_file_inside_lab_is_rejected(self):
        (self.lab / "slots/private.txt").write_bytes(b"PRIVATE")
        with self.assertRaises(LabError):
            run_fixture(self.root, mapping_count=1)

    def test_unauthorized_filesystem_target_outside_temp_is_denied(self):
        # No caller-specified target filename or directory is ever accepted.
        if os.name == "nt":
            self.skipTest("root drive layout is platform-dependent")
        from crane_restore_journal_lab import _check_layout
        with self.assertRaises(LabError):
            _check_layout(Path("/"))

    def test_invalid_count_does_not_touch_slots(self):
        for invalid in (0, 3, True, -1, 2.5):
            with self.subTest(value=invalid):
                with self.assertRaises(LabError):
                    run_fixture(self.root, mapping_count=invalid)
        self.assertEqual(self.slots(), (_old(1), _old(2)))

    def test_cli_interrupted_then_explicit_recovery(self):
        cli = Path(__file__).with_name("crane_restore_journal_lab.py")
        base = [sys.executable, str(cli), "--fixture-root", str(self.root)]
        attempted = subprocess.run(
            base + ["--archive", str(self.archive),
                    "--inventory", str(self.inventory),
                    "--inject-failure", "after_first_swap"],
            capture_output=True, text=True)
        self.assertEqual(attempted.returncode, 3, attempted.stderr)
        self.assertEqual(json.loads(attempted.stdout)["status"],
                         "fixture_interrupted_requires_recovery")
        fixed = subprocess.run(base + ["--recover"], capture_output=True,
                               text=True)
        self.assertEqual(fixed.returncode, 0, fixed.stderr)
        result = json.loads(fixed.stdout)
        self.assertEqual(result["status"], "fixture_rolled_back")
        self.assertEqual(self.slots(), (_old(1), _old(2)))
        self.assert_no_leaks(result)

    def test_cli_invalid_archive_does_not_echo_private_paths(self):
        cli = Path(__file__).with_name("crane_restore_journal_lab.py")
        malicious = self.root / "output/bad.cranect"
        malicious.write_bytes(("PRIVATE_" + PRIVATE).encode("ascii"))
        result = subprocess.run(
            [sys.executable, str(cli), "--fixture-root", str(self.root),
             "--archive", str(malicious), "--inventory", str(self.inventory)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"],
                         "fixture_lab_invalid_or_unsafe")
        self.assertNotIn(PRIVATE, result.stdout + result.stderr)
        self.assertEqual(self.slots(), (_old(1), _old(2)))

    def test_cli_recovery_after_durable_commit_keeps_new_fixture(self):
        cli = Path(__file__).with_name("crane_restore_journal_lab.py")
        base = [sys.executable, str(cli), "--fixture-root", str(self.root)]
        fail = subprocess.run(
            base + ["--archive", str(self.archive),
                    "--inventory", str(self.inventory),
                    "--inject-failure", "after_commit_record"],
            capture_output=True, text=True)
        self.assertEqual(fail.returncode, 3, fail.stderr)
        recovered = subprocess.run(base + ["--recover"],
                                   capture_output=True, text=True)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(json.loads(recovered.stdout)["status"],
                         "fixture_commit_preserved")
        self.assertEqual(self.slots(), (_new(1), _old(2)))
        self.assertEqual(list((self.lab / "journal").iterdir()), [])

    def test_cli_rejects_blocked_preflight_without_journal(self):
        self.update_inventory([{
            **target(APP1, DST1), "existingData": True,
        }], [mapping(APP1, SRC1, DST1)])
        cli = Path(__file__).with_name("crane_restore_journal_lab.py")
        rejected = subprocess.run(
            [sys.executable, str(cli), "--fixture-root", str(self.root),
             "--archive", str(self.archive), "--inventory", str(self.inventory)],
            capture_output=True, text=True)
        self.assertEqual(rejected.returncode, 2, rejected.stderr)
        self.assertEqual(json.loads(rejected.stdout)["status"],
                         "fixture_lab_invalid_or_unsafe")
        self.assertEqual(list((self.lab / "journal").iterdir()), [])
        self.assertEqual(self.slots(), (_old(1), _old(2)))


if __name__ == "__main__":
    unittest.main()
