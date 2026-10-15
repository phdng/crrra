"""C4 source contract: 8-field REAL-OBSERVED SHAPE with fake TEST VALUES.

The Chrome reference is ignored by Git and read only by the opt-in local
regression. This contract never authorizes iOS backup or restore.
"""
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[2]
tools = root / "reconstruction/tools"
module = (tools / "crane_backup_metadata.py").read_text(encoding="utf8")
writer = (tools / "crane_backup_fixture_writer.py").read_text(encoding="utf8")
tests = (tools / "test_crane_original_metadata_shape.py").read_text(encoding="utf8")
audit = (root / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf8")
workflow = (root / ".github/workflows/build.yml").read_text(encoding="utf8")
prefs = (root / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf8")
helper = (root / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf8")
expected = {
    "NSFileCreationDate", "NSFileModificationDate",
    "NSFileExtensionHidden", "NSFileOwnerAccountID",
    "NSFileOwnerAccountName", "NSFileGroupOwnerAccountID",
    "NSFileGroupOwnerAccountName", "NSFilePosixPermissions",
}
tree = ast.parse(module)
assignment = next(
    node for node in ast.walk(tree)
    if isinstance(node, ast.Assign) and
    any(isinstance(target, ast.Name) and
        target.id == "ORIGINAL_SAMPLE_EIGHT_FIELDS"
        for target in node.targets)
)
actual = {v.value for v in ast.walk(assignment.value)
          if isinstance(v, ast.Constant) and isinstance(v.value, str)}
assert actual == expected and len(actual) == 8
assert "def original_sample_shape_synthetic_attributes(" in module
for fake_token in (
    "crane-fixture-owner-NOT-IOS",
    "crane-fixture-group-NOT-IOS",
    "900001", "900002",
    "datetime(2001, 1, 1, 0, 0, 0)",
):
    assert fake_token in module
assert "attributes_available_from_stat(info" in module
assert "ORIGINAL_SAMPLE_EIGHT_FIELDS" in tests
assert "if metadata_profile == \"synthetic-original-eight-field\"" in writer
assert "else attributes_available_from_stat" in writer
assert "metadata_profile: str = \"host-stat\"" in writer
assert '"--metadata-profile"' in writer
assert '"synthetic-original-eight-field"' in writer
assert 'attribute_provider(source.lstat())' in writer
assert 'attribute_provider(' in writer
assert 'metadata_profile=metadata_profile' in writer
assert '"original_compatibility_proven": False' in writer
for literal in (
    "test_all_synthetic_file_and_directory_rows_match_eight_field_schema",
    "test_synthetic_ownership_never_uses_host_uid_gid",
    "test_default_mode_is_host_stat_and_does_not_fake_account_names",
    "test_reject_unrecognized_profile_before_output",
    "test_fixture_marker_remains_mandatory_in_synthetic_mode",
    "test_multi_synthetic_profile_applied_to_all_container_records",
    "test_original_chrome_eight_field_presence_and_types_match_fixture_shape",
):
    assert literal in tests
assert "@unittest.skipUnless(ORIGINAL_FIXTURE.is_file()" in tests
assert "test_crane_original_metadata_shape.py" in workflow
assert "check_original_metadata_shape_contract.py" in workflow
assert "synthetic-original-eight-field" in audit
assert 'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"' in prefs
assert 'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"' in prefs
assert "keychain restore unavailable" in helper
print("G-11 C4 fake eight-field Metadata.plist schema, local-only regression: PASS")
