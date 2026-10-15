"""G-11 offline metadata whitelist recovery anchored to CranePrefs original 0x2301C.

Source checks only; native macOS device parity is NOT proved by this contract.
"""
from pathlib import Path
import ast
import re

repo = Path(__file__).resolve().parents[2]
tool_root = repo / "reconstruction/tools"
module = (tool_root / "crane_backup_metadata.py").read_text(encoding="utf-8")
writer = (tool_root / "crane_backup_fixture_writer.py").read_text(encoding="utf-8")
comparison = (tool_root / "crane_backup_shape_compare.py").read_text(encoding="utf-8")
tests = (tool_root / "test_crane_backup_metadata.py").read_text(encoding="utf-8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf-8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf-8")

keys = {
    "NSFileBusy",
    "NSFileCreationDate",
    "NSFileExtensionHidden",
    "NSFileGroupOwnerAccountID",
    "NSFileGroupOwnerAccountName",
    "NSFileHFSCreatorCode",
    "NSFileHFSTypeCode",
    "NSFileImmutable",
    "NSFileModificationDate",
    "NSFileOwnerAccountID",
    "NSFileOwnerAccountName",
    "NSFilePosixPermissions",
}
tree = ast.parse(module)
declaration = next(
    node for node in ast.walk(tree)
    if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Name) and
            target.id == "WRITABLE_FILE_ATTRIBUTES"
            for target in node.targets)
)
actual = {
    node.value for node in ast.walk(declaration.value)
    if isinstance(node, ast.Constant) and isinstance(node.value, str)
}
assert actual == keys and len(actual) == 12, (actual - keys, keys - actual)

native = (repo / "Library/PreferenceBundles/CranePrefs.bundle/"
          "CranePrefs_export_for_ai/decompile")
list_file = native / "2301C.c"
filter_file = native / "23124.c"
callback_file = native / "23238.c"
restore_file = native / "2A848.c"
if list_file.is_file():
    text = list_file.read_text(encoding="utf-8")
    recovered = re.findall(r"v3\[\d+\] = (NSFile\w+);", text)
    assert set(recovered) == actual and len(recovered) == 12
if filter_file.is_file():
    assert '"allWritableFileAttributes"' in filter_file.read_text(
        encoding="utf-8")
if callback_file.is_file():
    assert '"containsObject:"' in callback_file.read_text(
        encoding="utf-8")
if restore_file.is_file():
    assert '"allWritableFileAttributes"' in restore_file.read_text(
        encoding="utf-8")

assert "NSFileModificationDate" in module
assert "NSFileCreationDate" in module
assert "st_birthtime" in module
assert "st_ctime" not in module.split("def attributes_available_from_stat")[1].split(
    "return filter_writable_file_attributes")[0].replace("never ctime", "")
assert "tzinfo=None" in module
assert "from crane_backup_metadata import (attributes_available_from_stat," in writer
assert "original_sample_shape_synthetic_attributes" in writer
assert "attribute_provider(source.lstat())" in writer
assert "attribute_provider(" in writer
assert "metadata_profile: str = \"host-stat\"" in writer
assert "from crane_backup_metadata import WRITABLE_FILE_ATTRIBUTES" in comparison
assert "KNOWN_METADATA_KEYS = WRITABLE_FILE_ATTRIBUTES" in comparison

for token in (
    "test_native_allowlist_is_exactly_twelve_and_immutable",
    "test_native_filter_removes_unwritable_fields_without_mutation",
    "test_stat_projection_uses_utc_naive_datetime",
    "test_birthtime_only_not_change_time",
    "test_no_invented_unsupported_platform_fields",
    "test_binary_plist_dates_roundtrip",
):
    assert token in tests
assert "test_crane_backup_metadata.py" in workflow
assert "check_backup_metadata_contract.py" in workflow
assert "crane_backup_metadata.py" in audit

prefs = (repo / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf-8")
for guard in (
    'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"',
    'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"',
):
    assert guard in prefs
print("G-11 original 12 writable metadata keys & offline projection: PASS")
