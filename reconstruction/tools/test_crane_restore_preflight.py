"""G-11 offline read-only restore preflight; never contacts a device."""
from __future__ import annotations

import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

import crane_backup_fixture_writer as writer
from crane_restore_preflight import preflight, PreflightError

APP = "com.example.crane-preflight"
OTHER_APP = "org.example.crane-preflight"
GROUP = "group.com.example.crane-preflight"
CID = "102BE628-72BB-4380-B3A1-BE2231C2AA91"
CID2 = "F764A70A-44B1-4F31-B7AC-87EDCF135C4E"
TARGET_ID = "C01F2E6F-5B40-41E0-BEAA-72120B304217"
SECOND_TARGET = "8F9A106F-A289-40BB-A94D-8A64069CBADC"
SECRET = "PRIVATE_PATH_SHOULD_NOT_BE_PRINTED"

def sample(app: str = APP, cid: str = CID) -> dict:
    return {
        "applicationIdentifier": app,
        "containerIdentifier": cid,
        "containerName": "Test Fixture " + SECRET,
        "originalPaths": {
            app: "/private/var/mobile/Test/" + SECRET,
            GROUP: "/private/var/mobile/Shared/" + SECRET,
        },
        "sourceDirectories": {app: "test/app", GROUP: "test/group"},
    }

def target(app: str = APP, cid: str = TARGET_ID,
           defaults: list[str] | None = None,
           selected: list[str] | None = None,
           active: bool = False, existing: bool = False) -> dict:
    return {
        "applicationIdentifier": app,
        "containerIdentifier": cid,
        "defaultAssociatedIdentifiers":
            defaults if defaults is not None else [app, GROUP],
        "targetAssociatedIdentifiers":
            selected if selected is not None else [app, GROUP],
        "active": active,
        "existingData": existing,
    }

def mapping(source_app: str = APP, source_cid: str = CID,
            target_app: str = APP, target_cid: str = TARGET_ID) -> dict:
    return {
        "sourceApplicationIdentifier": source_app,
        "sourceContainerIdentifier": source_cid,
        "targetApplicationIdentifier": target_app,
        "targetContainerIdentifier": target_cid,
    }

class PreflightTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="crane-preflight-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / writer.MARKER).write_bytes(writer.MARKER_CONTENT)
        (self.root / "output").mkdir()
        (self.root / "test/app").mkdir(parents=True)
        (self.root / "test/group").mkdir(parents=True)
        (self.root / "test/app/data.txt").write_bytes(b"DISPOSABLE")
        (self.root / "test/group/group.txt").write_bytes(b"GROUP")
        self.archive = self.create_archive("single.cranect", [sample()])
        self.inventory = self.root / "inventory.json"
        self.save([target()], [mapping()], free=10**9)

    def create_archive(self, name: str, rows: list[dict]) -> Path:
        (self.root / "manifest.json").write_text(
            json.dumps({"containers": rows}), encoding="utf-8")
        writer.write_fixture(self.root, manifest_name="manifest.json",
                             output_name=name)
        return self.root / "output" / name

    def save(self, targets, mappings, free=10**9):
        self.inventory.write_text(json.dumps({
            "targets": targets, "mappings": mappings, "freeBytes": free,
        }), encoding="utf-8")

    def assert_redacted(self, report: dict):
        payload = json.dumps(report, sort_keys=True)
        for forbidden in (APP, OTHER_APP, GROUP, CID, CID2, TARGET_ID,
                          SECOND_TARGET, SECRET, "/private/"):
            self.assertNotIn(forbidden, payload)

    def test_clean_single_is_advisory_not_restore_permission(self):
        before_archive = self.archive.read_bytes()
        before_inventory = self.inventory.read_bytes()
        report = preflight(self.archive, self.inventory)
        self.assertEqual(report["status"], "preflight_advisory_only")
        self.assertFalse(report["restore_executable"])
        self.assertFalse(report["original_compatibility_proven"])
        self.assertFalse(report["inventory_verified_against_device"])
        self.assertFalse(report["free_space_verified_on_device"])
        self.assertFalse(report["payload_crc_verified"])
        self.assertFalse(report["rollback_implemented"])
        self.assertFalse(report["wrote_files"])
        self.assertFalse(report["extracted"])
        self.assertFalse(report["keychain_contents_read"])
        self.assertEqual(report["reason_codes"], [])
        self.assertEqual(report["mapping_count"], 1)
        self.assertEqual(self.archive.read_bytes(), before_archive)
        self.assertEqual(self.inventory.read_bytes(), before_inventory)
        self.assert_redacted(report)

    def test_wrong_app_id_is_blocked(self):
        self.save([target(app=OTHER_APP, defaults=[APP,GROUP],
                          selected=[APP,GROUP])],
                  [mapping(target_app=OTHER_APP)])
        report = preflight(self.archive, self.inventory)
        self.assertIn("application_identifier_mismatch", report["reason_codes"])
        self.assertFalse(report["restore_executable"])
        self.assert_redacted(report)

    def test_missing_group_in_default_requires_confirmation(self):
        self.save([target(defaults=[APP], selected=[APP])], [mapping()])
        report = preflight(self.archive, self.inventory)
        self.assertIn("associated_identifier_confirmation_required",
                      report["reason_codes"])
        self.assertIn("target_associated_identifier_unavailable",
                      report["reason_codes"])
        self.assertTrue(report["mappings"][0]["group_confirmation_required"])
        self.assert_redacted(report)

    def test_additional_default_group_is_allowed(self):
        extra = "group.example.extra"
        self.save([target(defaults=[APP,GROUP,extra], selected=[APP,GROUP])],
                  [mapping()])
        report = preflight(self.archive, self.inventory)
        self.assertEqual(report["reason_codes"], [])

    def test_existing_data_and_active_target_block(self):
        self.save([target(active=True, existing=True)], [mapping()])
        report = preflight(self.archive, self.inventory)
        self.assertIn("overwrite_requires_snapshot_and_rollback",
                      report["reason_codes"])
        self.assertIn("target_active_reload_unverified",
                      report["reason_codes"])
        self.assertFalse(report["restore_executable"])

    def test_no_capacity_and_insufficient_estimate(self):
        self.save([target()], [mapping()], free=None)
        unknown = preflight(self.archive, self.inventory)
        self.assertIn("free_space_unknown", unknown["reason_codes"])
        self.save([target()], [mapping()], free=0)
        insufficient = preflight(self.archive, self.inventory)
        self.assertIn("insufficient_estimated_free_space",
                      insufficient["reason_codes"])
        self.assertGreater(insufficient["estimated_required_bytes"], 0)

    def test_multi_explicit_subset_mapping_is_supported(self):
        multi = self.create_archive("multi.cranebk",
                    [sample(), sample(OTHER_APP, CID2)])
        self.save([target()], [mapping()])
        report = preflight(multi, self.inventory)
        self.assertEqual(report["archive_container_count"], 2)
        self.assertEqual(report["mapping_count"], 1)
        self.assertEqual(report["reason_codes"], [])

    def test_multi_mapping_same_target_refused(self):
        multi = self.create_archive("multi.cranebk",
                    [sample(), sample(OTHER_APP, CID2)])
        self.save([target()], [mapping(),
                  mapping(source_app=OTHER_APP, source_cid=CID2)])
        with self.assertRaises(PreflightError):
            preflight(multi, self.inventory)

    def test_multi_app_mismatch_blocked(self):
        multi = self.create_archive("multi.cranebk",
                    [sample(), sample(OTHER_APP, CID2)])
        self.save([target()], [mapping(source_app=OTHER_APP,
                    source_cid=CID2)])
        report = preflight(multi, self.inventory)
        self.assertIn("application_identifier_mismatch", report["reason_codes"])

    def test_duplicate_source_and_inventory_entries_refused(self):
        self.save([target()], [mapping(), mapping()])
        with self.assertRaises(PreflightError):
            preflight(self.archive, self.inventory)
        self.save([target(), target()], [mapping()])
        with self.assertRaises(PreflightError):
            preflight(self.archive, self.inventory)

    def test_absent_backup_container_mapping_refused(self):
        self.save([target()], [mapping(source_cid=CID2)])
        with self.assertRaises(PreflightError):
            preflight(self.archive, self.inventory)

    def test_malformed_inventory_and_non_boolean_flags_refused(self):
        self.inventory.write_text("{not valid", encoding="utf8")
        with self.assertRaises(PreflightError):
            preflight(self.archive, self.inventory)
        self.save([target()], [mapping()])
        doc = json.loads(self.inventory.read_text())
        doc["targets"][0]["active"] = 1
        self.inventory.write_text(json.dumps(doc), encoding="utf8")
        with self.assertRaises(PreflightError):
            preflight(self.archive, self.inventory)

    def test_negative_or_excessive_free_space_refused(self):
        for cap in (-1, True, 2**64):
            with self.subTest(cap=cap):
                self.save([target()], [mapping()], free=cap)
                with self.assertRaises(PreflightError):
                    preflight(self.archive, self.inventory)

    def test_no_actual_device_path_is_read_from_inventory(self):
        item = target()
        item["dangerousRestorePath"] = "/private/var/mobile/" + SECRET
        self.save([item], [mapping()])
        with self.assertRaises(PreflightError):
            preflight(self.archive, self.inventory)

    def test_keychain_flag_blocks_without_reading_contents(self):
        backup = self.root / "output/single.cranect"
        buf = io.BytesIO()
        with zipfile.ZipFile(backup, "r") as existing:
            items = [(member.filename, existing.read(member))
                     for member in existing.infolist()]
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            for name, data in items:
                zf.writestr(name, data)
            zf.writestr("Keychain.plist", SECRET)
        backup.write_bytes(buf.getvalue())
        report = preflight(backup, self.inventory)
        self.assertIn("keychain_restore_backend_unavailable",
                      report["reason_codes"])
        self.assertTrue(report["mappings"][0]["keychain_present"])
        self.assertFalse(report["keychain_contents_read"])
        self.assert_redacted(report)

    def test_cli_statuses_and_private_identifiers_are_hidden(self):
        cli = Path(__file__).with_name("crane_restore_preflight.py")
        args = [sys.executable, str(cli), "--archive", str(self.archive),
                "--inventory", str(self.inventory)]
        ok = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertEqual(json.loads(ok.stdout)["status"],
                         "preflight_advisory_only")
        self.assertNotIn(APP, ok.stdout)
        self.save([target(active=True)], [mapping()])
        blocked = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(blocked.returncode, 1)
        self.assertEqual(json.loads(blocked.stdout)["status"],
                         "preflight_blocked")
        self.save([target()], [mapping(source_cid=CID2)])
        invalid = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(invalid.returncode, 2)
        self.assertEqual(json.loads(invalid.stdout)["status"],
                         "preflight_unavailable_or_invalid")
        self.assertNotIn(CID2, invalid.stdout)

if __name__ == "__main__":
    unittest.main()
