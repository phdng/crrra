"""G-11 metadata projection for disposable test archives.

CRPBackupContainer allWritableFileAttributes (original CranePrefs 0x2301C)
returns these twelve Foundation keys. Original 0x23124/sub_23238 filters
NSDictionary attributes to that allowlist; original restore 0x2A848
reapplies the same list. This module projects only objectively available
OS stat fields, not guessed iOS application ownership/security properties.

Never use host owner/group IDs or timestamps as evidence that a generated
archive can restore correctly on iOS.
"""
from __future__ import annotations

from datetime import datetime, timezone
import stat as stat_module
from typing import Any, Mapping

WRITABLE_FILE_ATTRIBUTES = frozenset({
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
})



# Controlled test vectors for the EIGHT FIELD signature observed in the
# user-provided original Chrome .cranect. These values are deliberately
# fictional and MUST NEVER be applied to an actual filesystem.
ORIGINAL_SAMPLE_EIGHT_FIELDS = frozenset({
    "NSFileCreationDate", "NSFileExtensionHidden",
    "NSFileGroupOwnerAccountID", "NSFileGroupOwnerAccountName",
    "NSFileModificationDate", "NSFileOwnerAccountID",
    "NSFileOwnerAccountName", "NSFilePosixPermissions",
})
_SYNTHETIC_DATE = datetime(2001, 1, 1, 0, 0, 0)
_SYNTHETIC_OWNER = "crane-fixture-owner-NOT-IOS"
_SYNTHETIC_GROUP = "crane-fixture-group-NOT-IOS"


def original_sample_shape_synthetic_attributes(info: Any) -> dict[str, Any]:
    """Eight-field *shape* from original sample, with fictitious test values.

    Intentionally independent from source UID/GID, OS account names and
    original archive data. The non-sensitive permission mode is derived from
    the supplied disposable stat input. Timestamps, ownership and hidden
    state are intentionally invented test VECTORS, not evidence of accuracy.
    This API is permitted ONLY for explicit, marked, disposable fixtures.
    """
    attributes = {
        "NSFileCreationDate": _SYNTHETIC_DATE,
        "NSFileModificationDate": _SYNTHETIC_DATE,
        "NSFileExtensionHidden": False,
        "NSFileOwnerAccountID": 900001,
        "NSFileGroupOwnerAccountID": 900002,
        "NSFileOwnerAccountName": _SYNTHETIC_OWNER,
        "NSFileGroupOwnerAccountName": _SYNTHETIC_GROUP,
        "NSFilePosixPermissions": stat_module.S_IMODE(info.st_mode),
    }
    assert frozenset(attributes) == ORIGINAL_SAMPLE_EIGHT_FIELDS
    return filter_writable_file_attributes(attributes)

def filter_writable_file_attributes(
    attributes: Mapping[str, Any],
) -> dict[str, Any]:
    """Equivalent allowlist projection to native 0x23124 + sub_23238.

    Does not mutate the source or trust its key order. Caller must ensure the
    dictionary values are plist-serializable when writing an archive.
    """
    return {name: value for name, value in attributes.items()
            if name in WRITABLE_FILE_ATTRIBUTES}


def _date_if_representable(timestamp: Any) -> datetime | None:
    try:
        date = datetime.fromtimestamp(timestamp, tz=timezone.utc)
        # plistlib's default binary writer uses naive UTC NSDate values.
        # Do not retain tzinfo (Python 3.13 raises on aware timestamps).
        return date.replace(tzinfo=None, microsecond=0)
    except (OSError, OverflowError, ValueError, TypeError):
        return None


def attributes_available_from_stat(info: Any) -> dict[str, Any]:
    """Best-effort synthetic NSFileManager attributes from an lstat result.

    Apple's NSFileCreationDate maps to birth time, never ctime (which is
    inode/change time on Linux). No inferred HFS flags, human account names,
    busy state, hidden state or immutable flag are emitted.
    """
    raw: dict[str, Any] = {
        "NSFilePosixPermissions": stat_module.S_IMODE(info.st_mode),
    }
    modification = _date_if_representable(info.st_mtime)
    if modification is not None:
        raw["NSFileModificationDate"] = modification
    birth_timestamp = getattr(info, "st_birthtime", None)
    if birth_timestamp is not None:
        creation = _date_if_representable(birth_timestamp)
        if creation is not None:
            raw["NSFileCreationDate"] = creation
    for stat_field, metadata_key in (
        ("st_uid", "NSFileOwnerAccountID"),
        ("st_gid", "NSFileGroupOwnerAccountID"),
    ):
        number = getattr(info, stat_field, None)
        if isinstance(number, int) and not isinstance(number, bool) and number >= 0:
            raw[metadata_key] = number
    return filter_writable_file_attributes(raw)
