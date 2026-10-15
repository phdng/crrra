"""G-11 Stage B: constrain offline writer to marked fixture staging, no app writes."""
from pathlib import Path
import ast
import json

repo = Path(__file__).resolve().parents[2]
tools = repo / "reconstruction/tools"
text = (tools / "crane_backup_fixture_writer.py").read_text(encoding="utf-8")
tests = (tools / "test_crane_backup_fixture_writer.py").read_text(encoding="utf-8")
ci = (repo / ".github/workflows/build.yml").read_text(encoding="utf-8")
prefs = (repo / "reconstruction/sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
helper = (repo / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(encoding="utf-8")

tree = ast.parse(text)
imports = [
    name.name.split(".")[0]
    for node in ast.walk(tree)
    if isinstance(node, ast.Import)
    for name in node.names
]
for forbidden in ("subprocess", "shutil", "ctypes", "requests", "socket"):
    assert forbidden not in imports, forbidden

assert 'MARKER = ".crane-disposable-fixture"' in text
assert 'MARKER_CONTENT = b"CRANE_DISPOSABLE_FIXTURE_V1\\n"' in text
assert "not path.is_symlink()" in text
assert "not child.is_symlink()" in text
assert "O_NOFOLLOW" in text
assert "opened.st_ino" in text and "opened.st_dev" in text
assert "MAX_INPUT_FILES" in text and "MAX_FILE_SIZE" in text
assert "MAX_INPUT_SIZE" in text
assert "set(item) ==" in text
assert "sourceDirectories" in text and "originalPaths" in text
assert "containerIdentifier" in text and "applicationIdentifier" in text
assert 'f"{container[\'applicationIdentifier\']}/"' in text
assert 'f"{container[\'containerIdentifier\']}/"' in text
assert "FMT_BINARY" in text and "containedContainers" in text
assert "from crane_backup_metadata import (attributes_available_from_stat," in text
assert "original_sample_shape_synthetic_attributes" in text
assert "attribute_provider(" in text
metadata_source = (tools / "crane_backup_metadata.py").read_text(encoding="utf-8")
assert '"NSFilePosixPermissions"' in metadata_source
assert '"NSFileModificationDate"' in metadata_source
assert "filter_writable_file_attributes" in metadata_source
assert "os.link(staging, target)" in text
assert "staging.unlink()" in text
assert "inspect_archive(staging, verify_payload=True)" in text
assert "synthetic_fixture_only_not_original_compatible" in text
assert "reserved Crane ZIP metadata" in text
assert "Keychain" in text and "password/Keychain not supported" in text
assert "writestr" in text and "ZipFile(staging, mode=\"x\"" in text
assert "write_fixture(args.fixture_root" in text
assert '"--fixture-root"' in text and '"--output"' in text

required_tests = (
    "test_single_binary_manifest_and_roundtrip_crc",
    "test_multi_root_index_and_roundtrip",
    "test_reject_unmarked_root_without_output",
    "test_reject_existing_file_preserving_exact_bytes",
    "test_reject_escape_and_untrusted_manifest_options",
    "test_reject_source_symlink",
    "test_reject_reserved_associated_id_and_unsafe_output",
    "test_fail_before_publish_and_cleanup_unique_staging",
    "test_cli_json_and_refusal_of_unauthorized_output",
)
for name in required_tests:
    assert name in tests, name

assert "test_crane_backup_fixture_writer.py" in ci
assert "check_backup_fixture_writer_contract.py" in ci
assert "crane_backup_fixture_writer.py" in audit
for row in (
    '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"]',
    '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]',
):
    assert row in prefs
assert "keychain restore unavailable" in helper
assert "reply(nil);" in helper

original_root = (repo / "Library/PreferenceBundles/CranePrefs.bundle/"
                 "CranePrefs_export_for_ai/decompile")
sources = {
    "24CF8": ["Info.plist", "Metadata.plist", "originalPaths"],
    "24948": ["writeFolderAtPath:", "writeFileAtPath:", "writeData:filename:"],
    "257AC": ["containedContainers"],
}
for imp, tokens in sources.items():
    source = original_root / (imp + ".c")
    if source.is_file():
        original = source.read_text(encoding="utf-8")
        for token in tokens:
            assert token in original, (imp, token)
print("G-11 offline disposable ZIP writer contract: PASS (original parity unverified)")
