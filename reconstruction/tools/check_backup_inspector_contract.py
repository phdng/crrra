"""G-11 Stage A — source/evidence and non-destructive CLI contracts.

The ZIP reader is intentionally a local, read-only offline tool; no app,
helper, or native backup/restore action is enabled by this stage.
"""
import ast
import json
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
tools = repo / "reconstruction/tools"
inspector = tools / "crane_backup_inspector.py"
tests = tools / "test_crane_backup_inspector.py"
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf-8")
source = inspector.read_text(encoding="utf-8")
test_source = tests.read_text(encoding="utf-8")
prefs = (repo / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf-8")
helper = (repo / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf-8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf-8")
tree = ast.parse(source)
calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
called_attrs = {node.func.attr for node in calls
                if isinstance(node.func, ast.Attribute)}
assert "extract" not in called_attrs
assert "extractall" not in called_attrs
assert "writestr" not in called_attrs
assert "write" not in called_attrs
assert "remove" not in called_attrs
assert "unlink" not in called_attrs
assert "replace" not in called_attrs
zipcalls = [call for call in calls if isinstance(call.func, ast.Attribute)
            and call.func.attr == "ZipFile"]
assert len(zipcalls) == 1
assert len(zipcalls[0].args) > 1
assert isinstance(zipcalls[0].args[1], ast.Constant)
assert zipcalls[0].args[1].value == "r"
assert "zipfile.ZIP_STORED" in source and "zipfile.ZIP_DEFLATED" in source
assert "MAX_MEMBERS" in source and "MAX_TOTAL_SIZE" in source
assert "MAX_COMPRESSION_RATIO" in source and "MAX_PLIST_BYTES" in source
assert "stat.S_IFLNK" in source
assert "originalPaths" in source and "applicationGroups" in source
assert "containedContainers" in source
assert "Keychain.plist" in source and "Metadata.plist" in source
assert "payload_crc_verified" in source and "keychain_contents_read" in source
assert "_verify_non_keychain_payloads(" in source
assert "MAX_VERIFY_BYTES" in source and "VERIFY_CHUNK_BYTES" in source
assert "name in keychain_names or item.is_dir()" in source
assert "if total_to_read > MAX_VERIFY_BYTES:" in source
assert "stream.read(VERIFY_CHUNK_BYTES)" in source
assert "verify_payload: bool = False" in source
assert '"--verify-payload"' in source
assert "non_keychain_payload_crc_verified" in source
assert "payload_crc_verified\": verify_payload and not keychain_names" in source
assert "unsupported_not_validated" in source
assert "structural_pass_not_verified" in source
assert "test_single_schema_is_structural_only_and_read_only" in test_source
assert "test_encrypted_archive_reports_unsupported_not_valid" in test_source
assert "test_reject_traversal_and_weird_member_names" in test_source
assert "test_reject_symlink_and_special_files" in test_source
assert "test_reject_oversized_plist_and_compression_bombs" in test_source
assert "test_missing_or_mismatched_multi_records" in test_source
assert "test_opt_in_stream_crc_for_non_keychain_files" in test_source
assert "test_opt_in_crc_skips_keychain_bytes_and_reports_incomplete" in test_source
assert "test_opt_in_rejects_local_header_filename_mismatch" in test_source
assert "test_opt_in_crc_budget_is_enforced_before_streaming" in test_source
assert "test_cli_opt_in_crc_flag_and_no_file_mutations" in test_source
assert "test_crane_backup_inspector.py" in workflow
assert "check_backup_inspector_contract.py" in workflow

# Do not change the existing safe guard to accidentally start restore.
for selector in (
    '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"]',
    '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]',
):
    assert selector in prefs
assert 'reply(nil);' in helper
assert "keychain restore unavailable" in helper

classes = json.loads((repo / "analysis/objc_classes.json").read_text(
    encoding="utf-8"))["CranePrefs"]
expected = {
    "CRPBackupOperation": {
        "processBackupOfContainer:": "0x24CF8",
        "addMultiBackupInformation": "0x257AC",
        "main": "0x25A8C",
    },
    "CRPRestoreOperation": {
        "isMultiContainerBackup": "0x28D90",
        "loadBackupInfo": "0x29504",
        "handleGroupIdentifierCheckForBackupContainer:targetContainer:": "0x2A298",
        "restoreBackupContainer:intoContainer:": "0x2ADA0",
        "updatePathsOfContainer:withBackupContainer:": "0x2B31C",
    },
}
for cls, methods in expected.items():
    discovered = {x["sel"]: x["imp"].upper() for x in
                  classes[cls]["instance_methods"]}
    for selector, address in methods.items():
        assert discovered.get(selector) == address.upper(), (cls, selector)

decompile = (repo / "Library/PreferenceBundles/CranePrefs.bundle/"
             "CranePrefs_export_for_ai/decompile")
for address, evidence in {
    "24CF8": ("Info.plist", "Keychain.plist", "Metadata.plist",
              "originalPaths"),
    "257AC": ("containedContainers",),
    "28D90": ("cranebk",),
    "26B3C": ("cranect",),
    "2ADA0": ("wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:",),
}.items():
    path = decompile / (address + ".c")
    if path.is_file():
        body = path.read_text(encoding="utf-8")
        for token in evidence:
            assert token in body, (address, token)

assert "crane_backup_inspector.py" in audit
print("Crane G-11 read-only archive inspector source safety: PASS (original ZIP unverified)")
