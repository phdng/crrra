"""G-11 C2 contract: read-only, privacy-redacted deep ZIP payload parity."""
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[2]
base = root / "reconstruction/tools"
source = (base / "crane_backup_payload_parity.py").read_text(encoding="utf8")
tests = (base / "test_crane_backup_payload_parity.py").read_text(encoding="utf8")
workflow = (root / ".github/workflows/build.yml").read_text(encoding="utf8")
docs = (root / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf8")
prefs = (root / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf8")
helper = (root / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf8")

tree = ast.parse(source)
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        assert all(part.name.split(".")[0] not in
                   {"shutil", "subprocess", "socket", "ctypes", "requests"}
                   for part in node.names)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        assert node.func.attr not in {
            "extract", "extractall", "write", "writestr", "unlink", "remove",
            "rename", "replace", "mkdir", "rmdir", "rmtree", "chmod", "chown",
            "link", "copy", "move",
        }, node.func.attr
assert "inspect_archive(reference, verify_payload=True)" in source
assert "inspect_archive(candidate, verify_payload=True)" in source
assert "compare_archives(reference, candidate, verify_payload=False)" in source
assert "MAX_VERIFY_BYTES" in source and "VERIFY_CHUNK_BYTES" in source
assert "hashlib.sha256()" in source
assert "with zf.open(info, \"r\") as stream:" in source
assert 'SPECIAL = frozenset(("Info.plist", "Metadata.plist", "Keychain.plist"))' in source
assert 'if relative != "Keychain.plist":' in source
assert "identities_ref != identities_candidate" in source
assert "before_ref[:2] == before_candidate[:2]" in source
assert "_identity(reference) != before_ref" in source
assert "_identity(candidate) != before_candidate" in source
assert "file_size_mismatches" in source
assert "equal_size_content_mismatches" in source
assert "missing_candidate_files" in source
assert "extra_candidate_files" in source
assert "missing_candidate_directories" in source
assert "different_plist_bytes" in source
assert '"keychain_contents_read": False' in source
assert '"files_extracted": False' in source
assert '"filesystem_writes": False' in source
assert '"original_compatibility_proven": False' in source
assert '"restore_safe": False' in source
assert "payload_and_metadata_bytes_match_not_proven" in source
assert "payload_or_metadata_differences" in source
assert "container_identity_or_kind_mismatch_uncompared" in source
assert "parity_unavailable_or_unsupported" in source
assert "except (ParityUnavailable, ComparisonUnavailable, InvalidArchive," in source
assert "test_crane_backup_payload_parity.py" in workflow
assert "check_backup_payload_parity_contract.py" in workflow
assert "crane_backup_payload_parity.py" in docs

for testcase in (
    "test_identical_unencrypted_single_has_byte_match_not_proof",
    "test_same_size_payload_mutation_detected_even_if_shape_matches",
    "test_metadata_value_change_detected_beyond_shape_fields",
    "test_compression_method_diff_even_with_identical_extracted_bytes",
    "test_keychain_present_in_both_is_never_opened",
    "test_kind_mismatch_inconclusive_not_pass",
    "test_container_id_mismatch_inconclusive",
    "test_archive_modified_during_hash_is_refused",
    "test_cli_exit_status_and_redaction",
    "test_inspector_crc_budget_cannot_be_bypassed",
):
    assert testcase in tests, testcase

assert 'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"' in prefs
assert 'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"' in prefs
assert "keychain restore unavailable" in helper
print("G-11 C2 bounded read-only, non-Keychain payload SHA-256 contract: PASS")
