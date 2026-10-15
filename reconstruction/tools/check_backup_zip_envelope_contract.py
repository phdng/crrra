"""G-11 C5 source contract: header-only ZIP envelope audit + fixture opt-in.

Original Crane sample is local-only. No native backup/restore, payload
extraction, device access, Keychain reads or invented ZIP64 support.
"""
import ast
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
tools = repo / "reconstruction/tools"
audit = (tools / "crane_backup_zip_envelope.py").read_text(encoding="utf-8")
writer = (tools / "crane_backup_fixture_writer.py").read_text(encoding="utf-8")
tests = (tools / "test_crane_backup_zip_envelope.py").read_text(encoding="utf-8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf-8")
docs = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf-8")
prefs = (repo / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf-8")
helper = (repo / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf-8")

for src in (audit,):
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            assert all(item.name.split(".")[0] not in {
                "shutil", "subprocess", "socket", "ctypes", "requests",
            } for item in node.names)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            assert node.func.attr not in {
                "extract", "extractall", "write", "writestr", "unlink",
                "remove", "rename", "replace", "mkdir", "rmdir", "rmtree",
                "chmod", "chown", "move", "copy",
            }, node.func.attr

for token in (
    "inspect_archive(input_path, verify_payload=False)",
    'with zipfile.ZipFile(input_path, mode="r") as zf:',
    "struct.unpack_from",
    "zip64_16_extra_entries",
    "all_macos_creator_19",
    "all_general_flag_0808",
    "all_zip64_16_extra",
    "all_requires_zip64_version_45",
    "info_first",
    "metadata_last",
    "directories_stored",
    "files_deflated",
    "different_feature_names",
    "Path(reference).resolve(strict=True) == Path(candidate).resolve(strict=True)",
    '"original_compatibility_proven": False',
    '"restore_safe": False',
    '"app_payload_read": False',
    '"keychain_contents_read": False',
    '"filesystem_writes": False',
    "zip_envelope_unavailable_or_invalid",
):
    assert token in audit, token

for token in (
    'zip_layout: str = "standard"',
    'zip_layout != "original-observed-structure"',
    "info.create_system = 19",
    "zipfile.ZIP_STORED if is_directory",
    "zipfile.ZIP_DEFLATED",
    'if metas[idx] and zip_layout != "original-observed-structure":',
    'if zip_layout == "original-observed-structure" and metas[0]:',
    "os.link(staging, target)",
    "inspect_archive(staging, verify_payload=True)",
    '"original_zip_envelope_proven": False',
    '"original_compatibility_proven": False',
    '"--zip-layout"',
):
    assert token in writer, token

for test in (
    "test_observed_layout_has_info_first_metadata_last",
    "test_observed_layout_uses_store_for_directories_deflate_files",
    "test_observed_layout_uses_original_creator19",
    "test_unimplemented_zip64_flag_parity_remains_explicitly_false",
    "test_default_writer_keeps_existing_ordering_and_compression",
    "test_original_observed_layout_rejects_unproven_multi",
    "test_eight_field_profile_and_observed_layout_can_combine",
    "test_genuine_single_backup_envelope_counts",
    "test_original_vs_fixture_exposes_unimplemented_envelope_parts",
    "test_no_overwrite_and_source_bytes_unchanged",
):
    assert test in tests, test

assert "@unittest.skipUnless(ORIGINAL_FIXTURE.is_file()" in tests
assert "check_backup_zip_envelope_contract.py" in workflow
assert "test_crane_backup_zip_envelope.py" in workflow
assert "crane_backup_zip_envelope.py" in docs
assert 'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"' in prefs
assert 'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"' in prefs
assert "keychain restore unavailable" in helper
print("G-11 C5 original ZIP envelope evidence & fixture-only layout: PASS")
