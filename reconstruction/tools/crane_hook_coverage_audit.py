"""G-09: reproducible textual hook-registration audit, NOT runtime parity.

The original 159-row CSV is recovered registration evidence, not a reliable
per-class ABI oracle (in particular 0xCBEC aliases classes). This script
retains every registration, searches current hook installer expressions,
and labels possible source matches without asserting actual runtime hook
installation, behavioral equivalence or a safe patch opportunity.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
import json
from pathlib import Path
import re
from typing import Iterable

REPO = Path(__file__).resolve().parents[2]
INDEX = REPO / "analysis/hooks_index.csv"
MATRIX = REPO / "reconstruction/HOOK_COVERAGE_MATRIX.json"
SOURCE_FILES = {
    "CraneSB.dylib": [
        "reconstruction/sources/cranesb/CRSpringBoard.m",
        "reconstruction/sources/cranesb/CRMenuHooks.m",
        "reconstruction/sources/cranesb/CRBadgeStore.m",
        "reconstruction/sources/cranesb/CRBadgeAction.m",
        "reconstruction/sources/cranesb/CRErrorAlerts.m",
        "reconstruction/sources/cranesb/CRActivator.m",
    ],
    "CraneSupport.dylib": [
        "reconstruction/sources/support/CRSupport.m",
        "reconstruction/sources/support/CRApsd.m",
        "reconstruction/sources/support/CRAccountsd.m",
        "reconstruction/sources/support/CRCfprefs.m",
        "reconstruction/sources/support/CRLsd.m",
        "reconstruction/sources/support/CRMCM.m",
        "reconstruction/sources/support/CRPkd.m",
        "reconstruction/sources/support/CRSecurityd.m",
    ],
    "CranePrefs": [
        "reconstruction/sources/prefs/CRPreferences.m",
        "reconstruction/sources/prefs/CRChoicyEditor.m",
    ],
}
REGISTER_RE = re.compile(r"\b(MSHookMessageEx|class_addMethod)\s*\(")
# Clang concatenates adjacent NSString/ordinary string literals:
# NSSelectorFromString(@"part1:" "part2:"). Restrict the parser to literal
# segments only; computed expressions and format strings remain unresolved.
_STRING = r'"(?:\\.|[^"\\])*"'
_SELECTOR_PARTS = rf'@{_STRING}(?:\s*{_STRING})*'
SELECTOR_DEF = re.compile(
    rf'\bSEL\s+(\w+)\s*=\s*NSSelectorFromString\s*\(\s*({_SELECTOR_PARTS})\s*\)',
    re.MULTILINE,
)
# A local SEL may also be initialized with the compile-time @selector(...)
# construct, e.g. SEL initSelector = @selector(init). This was the sole
# false missing registration in legacy CraneSB's force-touch init hook.
SELECTOR_AT_DEF = re.compile(
    r'\bSEL\s+(\w+)\s*=\s*@selector\s*\(\s*([A-Za-z_][A-Za-z_0-9:]*)\s*\)'
)
DIRECT_SELECTOR = re.compile(
    rf'^(?:NSSelectorFromString\s*\(\s*({_SELECTOR_PARTS})\s*\)|@selector\s*\(\s*([^)]*)\s*\))$'
)
_LITERAL_SEGMENT = re.compile(_STRING)


def _joined_literal(parts: str) -> str | None:
    pieces = [literal[1:-1] for literal in _LITERAL_SEGMENT.findall(parts)]
    # Selectors recovered here use literal ASCII punctuation only. Reject
    # escapes instead of guessing how the Objective-C compiler interprets
    # them (a false positive would corrupt the audit).
    if not pieces or any("\\" in piece for piece in pieces):
        return None
    return "".join(pieces)
# G-09 human-reviewed provenance hints for rows with no identical installer
# selector/API. These are ONLY pointers to current alternative code paths;
# they are NOT claims of hook/class/behavior parity. Keep every key explicit
# so unrelated identical selectors never inherit an adaptation label.
ALTERNATE_EVIDENCE = {
    ("CraneSB.dylib", "valueForUndefinedKey:"): (
        "alternative_class_method", "reconstruction/sources/cranesb/CRMenuHooks.m",
        "class_addMethod(created, undefinedSEL,",
    ),
    ("CraneSB.dylib", "updateConstraints"): (
        "visual_adapter_only", "reconstruction/sources/cranesb/CRMenuHooks.m",
        "static void CRMenuReserveBadgeSpacing(",
    ),
    ("CraneSB.dylib", "layoutSubviews"): (
        "visual_adapter_only", "reconstruction/sources/cranesb/CRMenuHooks.m",
        "static void CRMenuRestoreBadgeSpacing(",
    ),
    ("CraneSB.dylib", "badgeView"): (
        "visual_adapter_only", "reconstruction/sources/cranesb/CRMenuHooks.m",
        "static UIView *CRMenuCreateNativeBadgeView(",
    ),
    ("CraneSB.dylib", "setBadgeView:"): (
        "visual_adapter_only", "reconstruction/sources/cranesb/CRMenuHooks.m",
        "static void CRApplyBadgeToActionView(",
    ),
    ("CraneSB.dylib", "associatedApplicationID"): (
        "visual_adapter_only", "reconstruction/sources/cranesb/CRMenuHooks.m",
        "static id CRMenuFakeIconApplicationBundleID(",
    ),
    ("CraneSB.dylib", "setAssociatedApplicationID:"): (
        "visual_adapter_only", "reconstruction/sources/cranesb/CRMenuHooks.m",
        "static id CRMenuFakeIconApplicationBundleID(",
    ),
    ("CraneSB.dylib", "containsObject:"): (
        "alternative_class_method", "reconstruction/sources/cranesb/CRBadgeStore.m",
        "class_addMethod(subclass, containsSEL,",
    ),
    ("CraneSupport.dylib", "_xpc_connection_set_event_handler"): (
        "function_hook_alternative", "reconstruction/sources/support/CRMCM.m",
        "MSHookFunction((void *)&xpc_connection_set_event_handler,",
    ),
    ("CraneSupport.dylib", "handleSourceMessage:replyHandler:"): (
        "hook_wrapper_alternative", "reconstruction/sources/support/CRCfprefs.m",
        "CRPrefsHookMessage(daemonClass,",
    ),
    ("CraneSupport.dylib", "gHandleSourceMessageSym"): (
        "function_hook_alternative", "reconstruction/sources/support/CRCfprefs.m",
        "(void *)CRPrefsHandleSourceMessageV2,",
    ),
    ("CraneSupport.dylib", "gWithSourceForDomainHookSym"): (
        "function_hook_alternative", "reconstruction/sources/support/CRCfprefs.m",
        "(void *)CRPrefsWithSourceV3,",
    ),
}


def _reviewed_alternate(binary: str, selector: str) -> dict | None:
    hint = ALTERNATE_EVIDENCE.get((binary, selector))
    if hint is None:
        return None
    label, path, anchor = hint
    content = (REPO / path).read_text(encoding="utf-8")
    # Fail closed if a human-reviewed alternative disappears. Do not silently
    # keep a stale label merely because the original selector is still in CSV.
    occurrences = content.count(anchor)
    if occurrences == 0:
        raise ValueError(f"Alternative evidence changed: {path} / {anchor}")
    return {
        "kind": label,
        "file": path,
        "line": content[:content.index(anchor)].count("\n") + 1,
        "anchor": anchor,
        "anchor_occurrences": occurrences,
        "equivalence_verified": False,
    }


# 0xCBEC CSV class field aliases source classes and is NOT authoritative.
ALIAS_COLLAPSED_GROUPS = {("CraneSB.dylib", "_initNotificationSupport")}


def _mask_comments(code: str) -> str:
    """Replace comments with whitespace but preserve offsets/newlines.

    The scanner is intentionally conservative and recognizes quoted strings
    so URLs inside NSString literals cannot start a fake line comment.
    """
    result = list(code)
    i = 0
    state = "normal"
    while i < len(code):
        c = code[i]
        n = code[i + 1] if i + 1 < len(code) else ""
        if state == "normal":
            if c == '"':
                state = "string"
            elif c == "/" and n == "/":
                result[i] = result[i + 1] = " "
                i += 2
                state = "line"
                continue
            elif c == "/" and n == "*":
                result[i] = result[i + 1] = " "
                i += 2
                state = "block"
                continue
        elif state == "string":
            if c == "\\":
                i += 2
                continue
            if c == '"':
                state = "normal"
        elif state == "line":
            if c == "\n":
                state = "normal"
            else:
                result[i] = " "
        elif state == "block":
            if c == "*" and n == "/":
                result[i] = result[i + 1] = " "
                i += 2
                state = "normal"
                continue
            elif c != "\n":
                result[i] = " "
        i += 1
    return "".join(result)


def _arguments(source: str, start: int) -> list[str] | None:
    """Read the arguments to a balanced call from its opening '('."""
    if source[start] != "(":
        return None
    depth = 0
    bracket = 0
    brace = 0
    string = False
    args: list[str] = []
    begin = start + 1
    i = start
    while i < len(source):
        c = source[i]
        if string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                string = False
        elif c == '"':
            string = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                args.append(source[begin:i].strip())
                return args
        elif c == "[":
            bracket += 1
        elif c == "]":
            bracket -= 1
        elif c == "{":
            brace += 1
        elif c == "}":
            brace -= 1
        elif c == "," and depth == 1 and bracket == 0 and brace == 0:
            args.append(source[begin:i].strip())
            begin = i + 1
        i += 1
    return None


def _registrations(path: str) -> list[dict[str, str | int]]:
    code = _mask_comments((REPO / path).read_text(encoding="utf-8"))
    definitions = [(m.start(), m.group(1), _joined_literal(m.group(2)))
                   for m in SELECTOR_DEF.finditer(code)]
    definitions.extend((m.start(), m.group(1), m.group(2))
                       for m in SELECTOR_AT_DEF.finditer(code))
    found: list[dict[str, str | int]] = []
    for match in REGISTER_RE.finditer(code):
        args = _arguments(code, code.index("(", match.start(), match.end()))
        if not args or len(args) < 3:
            continue
        selector_expr = args[1].strip()
        direct = DIRECT_SELECTOR.fullmatch(selector_expr)
        selector = (_joined_literal(direct.group(1)) if direct.group(1)
                    else direct.group(2).strip()) if direct else None
        if selector is None:
            # Only accept a nearest earlier selector definition if it is
            # local to the registration (bounded by 6 KiB), NOT an unscoped
            # mention anywhere in the file.
            possible = [(pos, val) for pos, key, val in definitions
                        if key == selector_expr and val and
                        0 < match.start() - pos < 6144]
            if possible:
                selector = max(possible)[1]
        if not selector:
            continue
        # In-place selectors and dynamically replaced classes can differ from
        # recovered classes. Only the textual selector+API is matched.
        found.append({
            "api": match.group(1),
            "selector": selector,
            "file": path,
            "line": code.count("\n", 0, match.start()) + 1,
            "target_expression": args[0][:100],
            "impl_expression": args[2][:100],
        })
    return found


def build() -> dict:
    with INDEX.open(encoding="utf-8-sig", newline="") as stream:
        original = list(csv.DictReader(stream))
    if len(original) != 159:
        raise ValueError(f"Expected 159 recovered hook registrations, got {len(original)}")
    if Counter(row["binary"] for row in original) != {
        "CraneSB.dylib": 113, "CraneSupport.dylib": 45, "CranePrefs": 1,
    }:
        raise ValueError("Original per-binary registration counts changed")

    found: dict[tuple[str, str, str], list[dict]] = defaultdict(list)
    for binary, files in SOURCE_FILES.items():
        for path in files:
            for reg in _registrations(path):
                found[(binary, reg["api"], reg["selector"])].append(reg)
    duplicates = Counter((r["binary"], r["hook_api"], r["target_selector"])
                         for r in original)
    # Plain selector mentions in contract/unit test source are a signpost
    # for human review, NOT proof that the specific hook was exercised.
    tests = {}
    for pattern in ("check_*_contract.py", "test_crane_*.py"):
        for path in sorted((REPO / "reconstruction/tools").glob(pattern)):
            if path.name == "test_crane_hook_coverage_audit.py":
                continue  # the audit must not cite its own tests as hook tests
            tests[path.relative_to(REPO).as_posix()] = path.read_text(encoding="utf-8")

    rows = []
    for ordinal, orig in enumerate(original, 1):
        key = (orig["binary"], orig["hook_api"], orig["target_selector"])
        matches = sorted(found.get(key, []),
                         key=lambda e: (e["file"], e["line"], e["impl_expression"]))
        same_selector = duplicates[key]
        if not matches:
            state = "no_installer_candidate"
        elif same_selector > 1:
            state = "ambiguous_original_duplicate"
        elif len(matches) > 1:
            state = "multiple_installer_candidates"
        else:
            state = "textual_installer_candidate"
        alternate = (_reviewed_alternate(orig["binary"], orig["target_selector"])
                     if state == "no_installer_candidate" else None)
        rows.append({
            "ordinal": ordinal,
            "reviewed_alternative_not_parity": alternate,
            "original": {
                "binary": orig["binary"],
                "registering_function": orig["registration_fn"],
                "registration_address": orig["registration_addr"],
                "hook_api": orig["hook_api"],
                "target_class_as_indexed": orig["target_class"],
                "target_selector": orig["target_selector"],
                "hook_implementation": orig["hook_impl"],
            },
            "source_match_status": state,
            "original_class_attribution": (
                "alias_collapsed_unverified"
                if (orig["binary"], orig["registration_fn"]) in ALIAS_COLLAPSED_GROUPS
                else "indexed_not_runtime_verified"
            ),
            "source_candidates": matches,
            "source_candidate_count": len(matches),
            "test_source_selector_mentions_only": sorted(
                p for p, body in tests.items()
                if orig["target_selector"] in body
            ),
            "original_same_selector_api_count": same_selector,
            "runtime_verified": False,
            "behavior_verified": False,
        })
    return {
        "schema": "crane_hook_source_audit_v1",
        "interpretation": "Source-level selector+hook-API candidate ONLY; test file mentions are textual only, not proof of exercised behavior, class, ABI, runtime installation or device compatibility. Original 0xCBEC target class attribution is collapsed in the extracted index.",
        "original_index": "analysis/hooks_index.csv",
        "original_registrations": len(rows),
        "by_binary": dict(sorted(Counter(r["original"]["binary"] for r in rows).items())),
        "source_match_counts": dict(sorted(Counter(r["source_match_status"] for r in rows).items())),
        "unmatched_reviewed_alternative_count": sum(
            r["reviewed_alternative_not_parity"] is not None for r in rows
        ),
        "rows": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="write tracked JSON report")
    mode.add_argument("--check", action="store_true", help="verify committed report is fresh")
    args = parser.parse_args()
    generated = (json.dumps(build(), ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    if args.write:
        MATRIX.write_bytes(generated)
    elif not MATRIX.is_file() or MATRIX.read_bytes() != generated:
        print("G-09 hook coverage matrix stale; run --write")
        return 1
    report = json.loads(generated)
    print("G-09 original registrations:", report["original_registrations"],
          "source classifications:", report["source_match_counts"],
          "(no runtime parity claimed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
