#!/usr/bin/env python3
"""G-11 D1: pure in-memory atomic restore transaction MODEL, never a restore.

Inputs are a read-only G-11 D0 preflight of a disposable Crane ZIP and an
explicit JSON TEST inventory. The simulator models snapshots, staging,
promotion, verification and rollback of opaque virtual tokens only.

No ZIP extraction, file writes/moves/deletes, device runtime or Keychain access.
In particular, this is NOT a snapshot/rollback implementation for CraneManager.
Original 0x2B9B0 sequences check/extract/restore and 0x2ADA0 wipes target
BEFORE moving files, which cannot be safely wired to our incomplete manager.
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from crane_restore_preflight import preflight, PreflightError
from crane_backup_inspector import InvalidArchive, UnsupportedArchive


FAILPOINTS = (
    "after_snapshot", "after_staging", "after_first_promotion",
    "after_all_promotions", "after_verification", "before_commit",
)


class SimulationError(Exception):
    """An internal virtual stage failed (never a real filesystem failure)."""


def _assert_report(report: dict[str, Any]) -> None:
    if not isinstance(report, dict) or report.get("status") not in {
        "preflight_advisory_only", "preflight_blocked",
    }:
        raise SimulationError("invalid preflight report")
    # Even an advisory pass must explicitly be from the NON-EXECUTABLE D0
    # report shape, never a live restore permission or an invented inventory.
    expected = {
        "restore_executable": False,
        "original_compatibility_proven": False,
        "inventory_verified_against_device": False,
        "free_space_verified_on_device": False,
        "payload_crc_verified": False,
        "rollback_implemented": False,
        "wrote_files": False,
        "extracted": False,
        "keychain_contents_read": False,
    }
    if any(report.get(k) is not v for k, v in expected.items()):
        raise SimulationError("preflight report must be offline and non-executable")
    mappings = report.get("mappings")
    if not isinstance(mappings, list) or not 1 <= len(mappings) <= 50:
        raise SimulationError("invalid mapping count")
    if report.get("mapping_count") != len(mappings):
        raise SimulationError("mapping count mismatch")
    if any(not isinstance(row, dict) or
           row.get("index") != i or
           not isinstance(row.get("reason_codes"), list)
           for i, row in enumerate(mappings, 1)):
        raise SimulationError("invalid mapping rows")
    reasons = report.get("reason_codes")
    if not isinstance(reasons, list) or any(not isinstance(r, str) for r in reasons):
        raise SimulationError("invalid reason codes")
    if (report["status"] == "preflight_advisory_only") != (len(reasons) == 0):
        raise SimulationError("inconsistent preflight status")


def simulate_transaction(
    report: dict[str, Any], *, inject_failure: str | None = None,
) -> dict[str, Any]:
    """Simulate all-or-nothing multi-target restore with fault injection.

    Virtual state contains no file paths/content or real persistent data.
    Recovery must restore the original virtual state after ANY injection.
    """
    _assert_report(report)
    if inject_failure is not None and inject_failure not in FAILPOINTS:
        raise SimulationError("unrecognized injection point")
    count = report["mapping_count"]
    result: dict[str, Any] = {
        "status": "simulation_not_run_blocked",
        "simulated_targets": count,
        "simulated_transitions": [],
        "failure_injected": False,
        "simulated_snapshot_verified": False,
        "simulated_rollback_verified": False,
        "simulated_atomicity_pass": False,
        "restore_executable": False,
        "real_rollback_implemented": False,
        "device_data_touched": False,
        "filesystem_writes": False,
        "zip_extracted": False,
        "keychain_contents_read": False,
        "original_compatibility_proven": False,
    }
    if report["status"] != "preflight_advisory_only":
        return result

    # Each target begins with synthetic preexisting state, proving model
    # rollback covers both old data and multiple containers.
    state = {i: ("old", i) for i in range(1, count + 1)}
    baseline = dict(state)
    snapshot: dict[int, tuple[str, int]] = {}
    staged: dict[int, tuple[str, int]] = {}
    log: list[str] = []

    def transition(step: str) -> None:
        log.append(step)
        if inject_failure == step:
            raise SimulationError("simulated failure")

    try:
        snapshot = dict(state)
        transition("after_snapshot")
        staged = {i: ("new", i) for i in range(1, count + 1)}
        transition("after_staging")
        for index in range(1, count + 1):
            state[index] = staged[index]
            if index == 1:
                transition("after_first_promotion")
        transition("after_all_promotions")
        if state != staged or len(state) != count:
            raise SimulationError("virtual post-promotion mismatch")
        transition("after_verification")
        transition("before_commit")
        if state != staged:
            raise SimulationError("virtual commit invariant failed")
        log.append("simulated_commit")
        result["status"] = "simulation_committed_virtual_only"
        result["simulated_snapshot_verified"] = snapshot == baseline
        result["simulated_atomicity_pass"] = True
    except SimulationError:
        # No real work can escape this model, but still assert that a partially
        # promoted multi-container state is reverted to its virtual snapshot.
        state = dict(snapshot) if snapshot else dict(baseline)
        restored = state == baseline
        log.append("simulated_rollback")
        result["status"] = ("simulation_rolled_back_virtual_only" if restored
                            else "simulation_invariant_failed")
        result["failure_injected"] = inject_failure is not None
        result["simulated_snapshot_verified"] = bool(snapshot) and snapshot == baseline
        result["simulated_rollback_verified"] = restored
        result["simulated_atomicity_pass"] = restored

    result["simulated_transitions"] = log
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(
        "Read-only, in-memory Crane restore transaction fault simulation; "
        "NEVER modifies the device or extracts ZIP files"))
    parser.add_argument("--archive", required=True)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--inject-failure", choices=FAILPOINTS)
    args = parser.parse_args(argv)
    try:
        checked = preflight(args.archive, args.inventory)
        output = simulate_transaction(checked, inject_failure=args.inject_failure)
        exit_code = 0 if output["simulated_atomicity_pass"] else 1
    except (PreflightError, InvalidArchive, UnsupportedArchive, SimulationError,
            OSError, ValueError, TypeError, KeyError, RuntimeError):
        # Redact all exception data: fixture files can contain private IDs.
        output = {"status": "simulation_unavailable_or_invalid",
                  "restore_executable": False,
                  "device_data_touched": False}
        exit_code = 2
    print(json.dumps(output, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
