"""G-11 D3 redacted, read-only ZIP work-plan tests using synthetic archives."""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import crane_backup_fixture_writer as writer
import crane_restore_work_plan as work_plan
from crane_backup_inspector import InvalidArchive
from crane_restore_work_plan import PlanError, plan_restore, _classify_metadata

APP = "com.example.crane-work-plan"
SECOND = "org.example.crane-work-plan"
GROUP = "group.com.example.crane-work-plan"
CID = "AAAAAAAA-ABCD-4234-9ABC-000000000001"
CID2 = "BBBBBBBB-ABCD-4234-9ABC-000000000002"
DST = "CCCCCCCC-ABCD-4234-9ABC-000000000003"
DST2 = "DDDDDDDD-ABCD-4234-9ABC-000000000004"
SECRET = "ABSOLUTELY_PRIVATE_BUNDLE_OR_PATH"


def container(app, cid, folder):
    return {
        "applicationIdentifier": app,
        "containerIdentifier": cid,
        "containerName": SECRET,
        "originalPaths": {
            app: "/private/var/mobile/" + SECRET,
            GROUP: "/private/var/mobile/Shared/" + SECRET,
        },
        "sourceDirectories": {
            app: folder + "/app", GROUP: folder + "/group",
        },
    }


def inventory_target(app, cid, *, active=False, existing=False,
                     groups=None):
    group_ids = groups if groups is not None else [app, GROUP]
    return {
        "applicationIdentifier": app,
        "containerIdentifier": cid,
        "defaultAssociatedIdentifiers": group_ids,
        "targetAssociatedIdentifiers": group_ids,
        "active": active, "existingData": existing,
    }


def mapping(app, source, target):
    return {
        "sourceApplicationIdentifier": app,
        "sourceContainerIdentifier": source,
        "targetApplicationIdentifier": app,
        "targetContainerIdentifier": target,
    }


class RestoreWorkPlanTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="crane-d3-work-plan-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / writer.MARKER).write_bytes(writer.MARKER_CONTENT)
        (self.root / "output").mkdir()
        for folder in ("one", "two"):
            (self.root / folder / "app" / "Library" / "Preferences").mkdir(
                parents=True)
            (self.root / folder / "app" / "emptydir").mkdir()
            (self.root / folder / "group").mkdir()
            (self.root / folder / "app" / "Library" / "Preferences" /
             "setting.plist").write_bytes(b"NOT_REAL_PRIVATE")
            (self.root / folder / "group" / "empty.txt").write_bytes(b"")
        self.archive = self.make("single.cranect", [container(APP, CID, "one")])
        # Windows mode bits for directories may be 0o777. Normalize just
        # synthetic fixture metadata to deterministic unprivileged values.
        self.metadata_patch(lambda doc: [attrs.__setitem__(
            "NSFilePosixPermissions", 0o700) for attrs in doc.values()])
        self.inventory = self.root / "inventory.json"
        self.set_inventory([inventory_target(APP, DST)],
                           [mapping(APP, CID, DST)])

    def make(self, name, records):
        (self.root / "manifest.json").write_text(
            json.dumps({"containers": records}), encoding="utf8")
        writer.write_fixture(self.root, manifest_name="manifest.json",
                             output_name=name)
        return self.root / "output" / name

    def multi(self):
        self.archive = self.make("multi.cranebk",
                                 [container(APP, CID, "one"),
                                  container(SECOND, CID2, "two")])
        self.set_inventory([inventory_target(APP, DST),
                            inventory_target(SECOND, DST2)],
                           [mapping(APP, CID, DST),
                            mapping(SECOND, CID2, DST2)])

    def set_inventory(self, targets, maps, free=1000000000):
        self.inventory.write_text(
            json.dumps({"targets": targets, "mappings": maps,
                        "freeBytes": free}), encoding="utf8")

    def repack(self, replacements=None, omitted=(), additions=()):
        replacements = replacements or {}
        original = []
        with zipfile.ZipFile(self.archive, "r") as zf:
            for info in zf.infolist():
                original.append((info, zf.read(info)))
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as dst:
            for source_info, original_data in original:
                if source_info.filename in omitted:
                    continue
                new_info = zipfile.ZipInfo(source_info.filename)
                new_info.external_attr = source_info.external_attr
                new_info.create_system = source_info.create_system
                new_info.compress_type = source_info.compress_type
                dst.writestr(new_info, replacements.get(source_info.filename,
                                                       original_data))
            for name, data in additions:
                dst.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
        self.archive.write_bytes(buffer.getvalue())

    def metadata_patch(self, callback):
        with zipfile.ZipFile(self.archive) as zf:
            doc = plistlib.loads(zf.read("Metadata.plist"))
        callback(doc)
        self.repack({"Metadata.plist": plistlib.dumps(
            doc, fmt=plistlib.FMT_BINARY)})

    def no_private_output(self, result):
        dumped = json.dumps(result, sort_keys=True)
        for secret in (APP, SECOND, GROUP, CID, CID2, DST, DST2, SECRET,
                       "/private/", "setting.plist", "empty.txt"):
            self.assertNotIn(secret, dumped)
        self.assertIs(result["restore_executable"], False)
        self.assertIs(result["wrote_files"], False)
        self.assertIs(result["extracted"], False)
        self.assertIs(result["keychain_contents_read"], False)
        self.assertIs(result["rollback_implemented"], False)
        self.assertIs(result["original_compatibility_proven"], False)

    def test_single_work_plan_counts_and_never_authorizes_restore(self):
        a = self.archive.read_bytes()
        i = self.inventory.read_bytes()
        result = plan_restore(self.archive, self.inventory)
        self.assertEqual(result["status"], "work_plan_advisory_only")
        self.assertEqual(result["archive_kind"], "single")
        self.assertEqual(result["mapped_containers"], 1)
        self.assertEqual(result["unmapped_archive_containers"], 0)
        self.assertEqual(result["selected_payload_files"], 2)
        self.assertEqual(result["selected_payload_bytes_claimed"],
                         len(b"NOT_REAL_PRIVATE"))
        self.assertGreater(result["containers"][0]["explicit_directories"], 0)
        self.assertGreater(result["containers"][0]["metadata_records"], 0)
        self.assertEqual(result["reason_codes"], [])
        self.no_private_output(result)
        self.assertEqual((self.archive.read_bytes(),
                          self.inventory.read_bytes()), (a, i))

    def test_multi_subset_only_selected_entries_counted(self):
        self.multi()
        self.set_inventory([inventory_target(APP, DST)], [mapping(APP, CID, DST)])
        result = plan_restore(self.archive, self.inventory, verify_payload=True)
        self.assertEqual(result["mapped_containers"], 1)
        self.assertEqual(result["unmapped_archive_containers"], 1)
        self.assertEqual(result["archive_kind"], "multi")
        self.assertTrue(result["non_keychain_crc_verified"])
        self.assertEqual(result["selected_payload_files"], 2)
        self.no_private_output(result)

    def test_multi_all_records_and_order(self):
        self.multi()
        result = plan_restore(self.archive, self.inventory)
        self.assertEqual([row["index"] for row in result["containers"]], [1, 2])
        self.assertEqual(result["mapped_containers"], 2)
        self.assertEqual(result["selected_payload_files"], 4)
        self.no_private_output(result)

    def test_metadata_orphan_requires_review(self):
        def alter(doc):
            doc[f"{APP}/Library/Preferences/missing.plist"] = {
                "NSFilePosixPermissions": 0o600,
            }
        self.metadata_patch(alter)
        result = plan_restore(self.archive, self.inventory)
        self.assertIn("metadata_paths_without_zip_entries",
                      result["reason_codes"])
        self.assertEqual(result["containers"][0]["metadata_orphan_records"], 1)
        self.no_private_output(result)

    def test_unknown_attribute_redacted(self):
        def alter(doc):
            doc[next(iter(doc))][SECRET + "_unknown"] = SECRET
        self.metadata_patch(alter)
        result = plan_restore(self.archive, self.inventory)
        self.assertIn("metadata_unknown_attributes", result["reason_codes"])
        self.assertGreater(result["containers"][0][
            "metadata_unknown_attribute_records"], 0)
        self.no_private_output(result)

    def test_privileged_and_world_writable_permissions_review(self):
        for permission in (0o4777, 0o777, 0o2770):
            with self.subTest(permission=permission):
                self.assertIn("metadata_privileged_or_world_writable",
                    _classify_metadata({"NSFilePosixPermissions": permission}))

    def test_bad_metadata_types_review(self):
        for attrs in (
            {"NSFilePosixPermissions": True},
            {"NSFilePosixPermissions": -1},
            {"NSFilePosixPermissions": 0o100000},
            {"NSFileModificationDate": "Yesterday"},
            {"NSFileImmutable": "yes"},
            {"NSFileOwnerAccountID": False},
        ):
            with self.subTest(value=attrs):
                self.assertIn("metadata_invalid_attributes",
                              _classify_metadata(attrs))

    def test_invalid_metadata_values_block_plan_without_leaking(self):
        def alter(doc):
            doc[next(iter(doc))]["NSFilePosixPermissions"] = -5
        self.metadata_patch(alter)
        result = plan_restore(self.archive, self.inventory)
        self.assertIn("metadata_invalid_attributes", result["reason_codes"])
        self.no_private_output(result)

    def test_no_group_root_entry_detected(self):
        self.repack(omitted=(f"{GROUP}/", f"{GROUP}/empty.txt"))
        result = plan_restore(self.archive, self.inventory)
        self.assertIn("associated_data_absent_from_archive", result["reason_codes"])
        self.assertEqual(
            result["containers"][0]["associated_identifiers_without_payload"], 1)
        self.no_private_output(result)

    def test_preflight_target_active_and_existing_data(self):
        self.set_inventory([inventory_target(APP, DST, active=True,
                                             existing=True)],
                           [mapping(APP, CID, DST)])
        result = plan_restore(self.archive, self.inventory)
        self.assertIn("target_active_reload_unverified", result["reason_codes"])
        self.assertIn("overwrite_requires_snapshot_and_rollback",
                      result["reason_codes"])
        self.no_private_output(result)

    def test_keychain_presence_never_read(self):
        self.repack(additions=(("Keychain.plist", SECRET.encode()),))
        result = plan_restore(self.archive, self.inventory, verify_payload=True)
        self.assertIn("keychain_restore_backend_unavailable",
                      result["reason_codes"])
        self.assertTrue(result["containers"][0]["keychain_present"])
        self.assertTrue(result["non_keychain_crc_verified"])
        self.no_private_output(result)

    def test_invalid_filename_does_not_leak(self):
        self.repack(additions=(("../" + SECRET + "/file", b"malicious"),))
        cli = Path(__file__).with_name("crane_restore_work_plan.py")
        response = subprocess.run(
            [sys.executable, str(cli), "--archive", str(self.archive),
             "--inventory", str(self.inventory)],
            capture_output=True, text=True)
        self.assertEqual(response.returncode, 2, response.stderr)
        self.assertEqual(json.loads(response.stdout)["status"],
                         "work_plan_invalid_or_unavailable")
        self.assertNotIn(SECRET, response.stdout + response.stderr)

    def test_optional_crc_fails_closed_for_corrupted_file(self):
        # Corrupt the CENTRAL DIRECTORY CRC of one ordinary data file,
        # not the Info/Metadata bytes opened by a default structural pass.
        raw = bytearray(self.archive.read_bytes())
        target = f"{APP}/Library/Preferences/setting.plist".encode()
        with zipfile.ZipFile(self.archive) as zf:
            offset = zf.start_dir
        while raw[offset:offset+4] == b"PK\x01\x02":
            name_length = int.from_bytes(raw[offset+28:offset+30], "little")
            entry = bytes(raw[offset+46:offset+46+name_length])
            if entry == target:
                raw[offset+16] ^= 1
                break
            offset += 46 + name_length + int.from_bytes(
                raw[offset+30:offset+32], "little") + int.from_bytes(
                raw[offset+32:offset+34], "little")
        else:
            self.fail("missing data entry in ZIP central directory")
        self.archive.write_bytes(raw)
        result = plan_restore(self.archive, self.inventory)
        self.assertFalse(result["non_keychain_crc_verified"])
        with self.assertRaises(InvalidArchive):
            plan_restore(self.archive, self.inventory, verify_payload=True)

    def test_cli_success_blocked_and_identity_redaction(self):
        script = Path(__file__).with_name("crane_restore_work_plan.py")
        argv = [sys.executable, str(script), "--archive", str(self.archive),
                "--inventory", str(self.inventory)]
        output = subprocess.run(argv, capture_output=True, text=True)
        self.assertEqual(output.returncode, 0, output.stderr)
        self.assertEqual(json.loads(output.stdout)["status"],
                         "work_plan_advisory_only")
        self.assertNotIn(APP, output.stdout)
        self.set_inventory([inventory_target(APP, DST, active=True)],
                           [mapping(APP, CID, DST)])
        blocked = subprocess.run(argv, capture_output=True, text=True)
        self.assertEqual(blocked.returncode, 1)
        self.assertEqual(json.loads(blocked.stdout)["status"],
                         "work_plan_blocked_or_review_required")
        self.assertNotIn(APP, blocked.stdout)

    def test_no_zip_extract_or_app_payload_reads(self):
        def deny(*args, **kwargs):
            raise AssertionError("extraction attempted")
        original_open = zipfile.ZipFile.open
        observed: list[str] = []

        def guarded_open(zf, entry, *args, **kwargs):
            name = entry.filename if isinstance(entry, zipfile.ZipInfo) else entry
            observed.append(name)
            if not name.endswith(("Info.plist", "Metadata.plist")):
                raise AssertionError("private app/Keychain payload opened")
            return original_open(zf, entry, *args, **kwargs)
        with patch.object(zipfile.ZipFile, "extract", side_effect=deny), \
             patch.object(zipfile.ZipFile, "extractall", side_effect=deny), \
             patch.object(zipfile.ZipFile, "open", new=guarded_open):
            result = plan_restore(self.archive, self.inventory)
        self.assertTrue(observed)
        self.no_private_output(result)

    def test_archive_changed_during_scan_denied(self):
        original_inventory = work_plan._inventory

        def changed_inventory(path):
            value = original_inventory(path)
            original = self.archive.stat()
            os.utime(self.archive, ns=(original.st_atime_ns,
                                       original.st_mtime_ns + 1_000_000_000))
            return value
        with patch.object(work_plan, "_inventory",
                          side_effect=changed_inventory):
            with self.assertRaises(PlanError):
                plan_restore(self.archive, self.inventory)

    def test_archive_symlink_rejected_where_supported(self):
        alias = self.root / "archive-alias.cranect"
        try:
            alias.symlink_to(self.archive)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlink not supported: {exc}")
        with self.assertRaises(PlanError):
            plan_restore(alias, self.inventory)


if __name__ == "__main__":
    unittest.main()
