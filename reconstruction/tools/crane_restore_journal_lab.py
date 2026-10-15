#!/usr/bin/env python3
"""G-11 D2: crash-recovery experiment for SYNTHETIC marker files ONLY.

Never run against iOS paths or application data. The ONLY writable tree is a
double-marked, pre-existing disposable fixture located under the OS temp dir:
  <temp>/<fixture>/.crane-disposable-fixture
  <temp>/<fixture>/transaction-lab/.crane-transaction-lab
  <temp>/<fixture>/transaction-lab/{slots,incoming,journal}/

Only hard-coded slot-1.txt / slot-2.txt with EXACT synthetic token bytes may be
read or changed; the journal contains only those tokens. Source ZIP is NEVER
extracted. A faultpoint deliberately leaves a durable state for later recovery.
No real iPhone snapshot, atomic multi-container commit, or Keychain support.
"""
from __future__ import annotations

import argparse
import errno
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import zipfile
from typing import Any

from crane_backup_fixture_writer import MARKER, MARKER_CONTENT
from crane_restore_preflight import preflight, PreflightError
from crane_backup_inspector import InvalidArchive, UnsupportedArchive

LAB_MARKER = ".crane-transaction-lab"
LAB_MARKER_CONTENT = b"CRANE_TRANSACTION_LAB_V1\n"
LAB_DIR = "transaction-lab"
MAX_SLOTS = 2
FAILPOINTS = ("after_journal", "after_first_swap",
              "after_all_swaps", "after_commit_record")
STATE = "state.json"
TEMP_STATE = "state.json.tmp"


class LabError(Exception):
    """Fixed-layout lab guard or transaction invariant failed."""


class InjectedCrash(LabError):
    """Intentional process interruption; do NOT auto-rollback."""


def _ensure(condition: bool) -> None:
    if not condition:
        raise LabError("lab guard/invariant denied")


def _old(i: int) -> bytes:
    return f"CRANE_LAB_OLD_SLOT_{i}\n".encode("ascii")


def _new(i: int) -> bytes:
    return f"CRANE_LAB_NEW_SLOT_{i}\n".encode("ascii")


def _slot(i: int) -> str:
    _ensure(1 <= i <= MAX_SLOTS)
    return f"slot-{i}.txt"


def _regular(path: Path, allowed_size: int = 256) -> bytes:
    _ensure(not path.is_symlink())
    st = path.lstat()
    _ensure(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and
            st.st_size <= allowed_size)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    fd = os.open(path, flags)
    try:
        actual = os.fstat(fd)
        _ensure(stat.S_ISREG(actual.st_mode) and actual.st_nlink == 1 and
                (actual.st_dev, actual.st_ino, actual.st_size) ==
                (st.st_dev, st.st_ino, st.st_size))
        with os.fdopen(fd, "rb", closefd=False) as handle:
            value = handle.read(allowed_size + 1)
        _ensure(len(value) == st.st_size)
        return value
    finally:
        os.close(fd)


def _directory(path: Path) -> Path:
    _ensure(not path.is_symlink())
    _ensure(path.is_dir() and stat.S_ISDIR(path.lstat().st_mode))
    return path


def _check_layout(root_arg: str | Path) -> tuple[Path, Path, Path, Path]:
    source = Path(root_arg).absolute()
    _ensure(not source.is_symlink())
    root = _directory(source.resolve(strict=True))
    temp_root = Path(tempfile.gettempdir()).resolve(strict=True)
    # Require a NEW child of OS temporary directory, not the temp root itself.
    _ensure(root != temp_root and temp_root in root.parents)
    _ensure(_regular(root / MARKER) == MARKER_CONTENT)
    lab = _directory(root / LAB_DIR)
    _ensure(_regular(lab / LAB_MARKER) == LAB_MARKER_CONTENT)
    slots = _directory(lab / "slots")
    incoming = _directory(lab / "incoming")
    journal = _directory(lab / "journal")
    # No path component from input is ever joined below the selected root.
    _ensure(set(p.name for p in lab.iterdir()) ==
            {LAB_MARKER, "slots", "incoming", "journal"})
    for folder in (slots, incoming):
        _ensure({p.name for p in folder.iterdir()} ==
                {_slot(1), _slot(2)})
    _ensure({p.name for p in journal.iterdir()} <= {
        STATE, TEMP_STATE, "backup-1.txt", "backup-2.txt",
        "staged-1.txt", "staged-2.txt",
    })
    return slots, incoming, journal, lab


def _sync_dir(path: Path) -> None:
    # On Windows directory fsync is not exposed by the Python stdlib. This
    # remains a lab exercise, NOT a cross-platform crash-safety guarantee.
    if os.name != "posix":
        return
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        try:
            os.fsync(fd)
        except OSError as exc:
            # Some macOS/filesystem combinations reject directory fsync.
            # A lab may run without it, but NEVER claim durable crash safety.
            if exc.errno not in (errno.EINVAL, errno.ENOTSUP,
                                 errno.EOPNOTSUPP):
                raise
    finally:
        os.close(fd)


def _create_file(path: Path, value: bytes) -> None:
    flags = (os.O_WRONLY | os.O_CREAT | os.O_EXCL |
             getattr(os, "O_BINARY", 0))
    fd = os.open(path, flags, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as handle:
            handle.write(value)
            handle.flush()
            os.fsync(fd)
    finally:
        os.close(fd)


def _update_state(journal: Path, phase: str, count: int) -> None:
    _ensure(phase in ("prepared", "committed") and count in (1, 2))
    tmp = journal / TEMP_STATE
    _create_file(tmp, json.dumps({"version": 1, "phase": phase,
                                  "count": count}, sort_keys=True).encode("ascii"))
    os.replace(tmp, journal / STATE)
    _sync_dir(journal)


def _read_state(journal: Path) -> tuple[str, int] | None:
    state = journal / STATE
    if not state.exists() and not state.is_symlink():
        return None
    try:
        doc = json.loads(_regular(state).decode("ascii"))
    except (ValueError, UnicodeError) as exc:
        raise LabError("journal corrupted") from exc
    _ensure(type(doc) is dict and set(doc) == {"version", "phase", "count"}
            and type(doc["version"]) is int and doc["version"] == 1
            and type(doc["count"]) is int and doc["count"] in (1, 2)
            and doc["phase"] in ("prepared", "committed"))
    return doc["phase"], doc["count"]


def _cleanup(journal: Path, count: int) -> None:
    # Called only after verified recovery or durable commit record. Remove
    # persistent state LAST, so interrupted cleanup can resume idempotently.
    for i in range(1, count + 1):
        for part in ("backup", "staged"):
            candidate = journal / f"{part}-{i}.txt"
            if candidate.exists() or candidate.is_symlink():
                expected = _old(i) if part == "backup" else _new(i)
                _ensure(_regular(candidate) == expected)
                candidate.unlink()
    _sync_dir(journal)
    (journal / STATE).unlink()
    _sync_dir(journal)


def recover_fixture(root: str | Path) -> dict[str, Any]:
    slots, _, journal, _ = _check_layout(root)
    record = _read_state(journal)
    _ensure(record is not None)
    phase, count = record
    _ensure(not (journal / TEMP_STATE).exists())
    if phase == "prepared":
        # Also support a process interrupted MID-recovery: a slot already
        # restored to OLD may have consumed its backup via os.replace.
        # Validate every remaining backup before any further mutation.
        for i in range(1, count + 1):
            current = _regular(slots / _slot(i))
            _ensure(current in (_old(i), _new(i)))
            backup = journal / f"backup-{i}.txt"
            if backup.exists() or backup.is_symlink():
                _ensure(_regular(backup) == _old(i))
            else:
                _ensure(current == _old(i))
        for i in range(1, count + 1):
            if _regular(slots / _slot(i)) == _new(i):
                # Atomic single-file replacement; NOT multi-file atomicity.
                os.replace(journal / f"backup-{i}.txt", slots / _slot(i))
                _sync_dir(slots)
        _ensure(all(_regular(slots / _slot(i)) == _old(i)
                    for i in range(1, count + 1)))
        outcome = "fixture_rolled_back"
    else:
        _ensure(all(_regular(slots / _slot(i)) == _new(i)
                    for i in range(1, count + 1)))
        outcome = "fixture_commit_preserved"
    _cleanup(journal, count)
    return {"status": outcome, "fixture_only": True,
            "real_restore_supported": False, "real_rollback_implemented": False,
            "slots": count}


def run_fixture(root: str | Path, *, mapping_count: int,
                inject_failure: str | None = None) -> dict[str, Any]:
    _ensure(type(mapping_count) is int and 1 <= mapping_count <= MAX_SLOTS)
    _ensure(inject_failure is None or inject_failure in FAILPOINTS)
    slots, incoming, journal, _ = _check_layout(root)
    _ensure(not list(journal.iterdir()))
    for i in range(1, MAX_SLOTS + 1):
        _ensure(_regular(slots / _slot(i)) == _old(i))
        _ensure(_regular(incoming / _slot(i)) == _new(i))
    # All snapshots and prepared data are written and fsynced BEFORE journal
    # marks transaction prepared; no mutation occurs before the commit log.
    for i in range(1, mapping_count + 1):
        _create_file(journal / f"backup-{i}.txt", _old(i))
        _create_file(journal / f"staged-{i}.txt", _new(i))
    _sync_dir(journal)
    _update_state(journal, "prepared", mapping_count)

    def fail_at(point: str) -> None:
        if inject_failure == point:
            raise InjectedCrash("injected failure requires explicit --recover")

    fail_at("after_journal")
    for i in range(1, mapping_count + 1):
        os.replace(journal / f"staged-{i}.txt", slots / _slot(i))
        _sync_dir(slots)
        if i == 1:
            fail_at("after_first_swap")
    fail_at("after_all_swaps")
    _ensure(all(_regular(slots / _slot(i)) == _new(i)
                for i in range(1, mapping_count + 1)))
    _update_state(journal, "committed", mapping_count)
    fail_at("after_commit_record")
    _cleanup(journal, mapping_count)
    return {"status": "fixture_committed", "fixture_only": True,
            "real_restore_supported": False, "real_rollback_implemented": False,
            "slots": mapping_count}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Double-marked TEMP-ONLY fixed-token filesystem journal lab; "
        "no iPhone data, no backup ZIP extraction, no production restore"))
    parser.add_argument("--fixture-root", required=True)
    parser.add_argument("--archive", help="required for new run, read-only preflight")
    parser.add_argument("--inventory", help="required for new run, read-only preflight")
    parser.add_argument("--recover", action="store_true",
                        help="resume journal recovery (no ZIP needed)")
    parser.add_argument("--inject-failure", choices=FAILPOINTS)
    args = parser.parse_args(argv)
    try:
        if args.recover:
            _ensure(not args.archive and not args.inventory and
                    args.inject_failure is None)
            output = recover_fixture(args.fixture_root)
        else:
            _ensure(args.archive is not None and args.inventory is not None)
            checked = preflight(args.archive, args.inventory)
            _ensure(checked["status"] == "preflight_advisory_only" and
                    checked["restore_executable"] is False)
            output = run_fixture(args.fixture_root,
                                 mapping_count=checked["mapping_count"],
                                 inject_failure=args.inject_failure)
        code = 0
    except InjectedCrash:
        output, code = ({"status": "fixture_interrupted_requires_recovery",
                         "real_restore_supported": False}, 3)
    except (LabError, PreflightError, InvalidArchive, UnsupportedArchive,
            zipfile.BadZipFile, OSError, ValueError, TypeError, KeyError,
            RuntimeError):
        output, code = ({"status": "fixture_lab_invalid_or_unsafe",
                         "real_restore_supported": False}, 2)
    print(json.dumps(output, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
