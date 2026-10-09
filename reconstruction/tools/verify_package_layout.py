#!/usr/bin/env python3
"""Verify that a built package contains the recovered static layout and binaries."""

from __future__ import annotations

import pathlib
import sys


COMPILED_ARTIFACTS = (
    "Library/MobileSubstrate/DynamicLibraries/ Crane.dylib",
    "Library/MobileSubstrate/DynamicLibraries/CraneSB.dylib",
    "Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib",
    "Library/PreferenceBundles/CranePrefs.bundle/CranePrefs",
    "usr/lib/libcrane.dylib",
    "usr/local/libexec/cranehelperd",
    "usr/local/bin/cranehelperd_start",
)


def main(root_arg: str) -> int:
    project = pathlib.Path(__file__).resolve().parents[1]
    layout = project / "layout"
    root = pathlib.Path(root_arg).resolve()

    if not root.is_dir():
        print(f"FAIL package root does not exist: {root}")
        return 1

    expected = {
        p.relative_to(layout).as_posix()
        for p in layout.rglob("*")
        if p.is_file()
    }
    expected.update(COMPILED_ARTIFACTS)

    failures = 0
    for rel in sorted(expected):
        path = root / rel
        if path.is_file():
            print(f"OK   {rel}")
        else:
            failures += 1
            print(f"MISS {rel}")

    rootless_prefix = root / "var" / "jb"
    if failures and rootless_prefix.is_dir():
        print(
            "\nHINT: package contains var/jb; this reconstruction targets the "
            "recovered rootful install paths."
        )

    print(f"\n{len(expected)} required package files checked, {failures} missing")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "pkg"))
