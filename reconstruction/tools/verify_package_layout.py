#!/usr/bin/env python3
"""Verify that a built package contains the recovered static layout and binaries."""

from __future__ import annotations

import pathlib
import plistlib
import stat
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


def main(root_arg: str, control_arg: str | None = None) -> int:
    project = pathlib.Path(__file__).resolve().parents[1]
    layout = project / "layout"
    root = pathlib.Path(root_arg).resolve()

    if not root.is_dir():
        print(f"FAIL package root does not exist: {root}")
        return 1

    expected = {
        p.relative_to(layout).as_posix()
        for p in layout.rglob("*")
        if p.is_file() and p.relative_to(layout).parts[0] != "DEBIAN"
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

    # Presence alone is insufficient for a Mach-service daemon: verify the
    # exact installed job registration and an executable helper. This is
    # package inspection only, NOT a claim that launchd bootstrapped the job.
    plist_path = root / "Library/LaunchDaemons/com.opa334.cranehelperd.plist"
    helper_path = root / "usr/local/libexec/cranehelperd"
    if plist_path.is_file():
        try:
            job = plistlib.loads(plist_path.read_bytes())
            valid = (
                isinstance(job, dict)
                and job.get("Label") == "com.opa334.cranehelperd"
                and job.get("Program") == "/usr/local/libexec/cranehelperd"
                and job.get("UserName") == "root"
                and job.get("RunAtLoad") is True
                and job.get("KeepAlive") is True
                and job.get("MachServices") == {
                    "com.opa334.cranehelperd.xpc": True,
                    "com.opa334.cranehelperd.preferences.xpc": True,
                }
            )
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
            valid = False
        if valid:
            print("OK   helper launchd plist: label, executable and MachServices")
        else:
            failures += 1
            print("FAIL helper launchd plist: invalid job/MachServices/Program")
    if helper_path.is_file():
        if helper_path.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
            print("OK   cranehelperd has execute permission")
        else:
            failures += 1
            print("FAIL cranehelperd is not executable in package")

    # The app-side runtime_report uses the two exact service-specific libSandy
    # Mach extension classes recovered in CraneSupport/CraneRB. The package must
    # not accidentally widen this app sandbox exception (AllowedProcesses='*'
    # is necessary for arbitrary Crane-managed apps).
    app_profile = root / "Library/libSandy/CraneAppRuntime.plist"
    if app_profile.is_file():
        try:
            actual_profile = plistlib.loads(app_profile.read_bytes())
            valid_profile = actual_profile == {
                "AllowedProcesses": ["*"],
                "Extensions": [{
                    "type": "mach",
                    "extension_class": "com.apple.app-sandbox.mach",
                    "mach_name": "com.opa334.cranehelperd.xpc",
                }, {
                    "type": "mach",
                    "extension_class": "com.apple.security.exception.mach-lookup.global-name",
                    "mach_name": "com.opa334.cranehelperd.xpc",
                }],
            }
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
            valid_profile = False
        if valid_profile:
            print("OK   app runtime sandbox: exact helper Mach service classes")
        else:
            failures += 1
            print("FAIL app runtime sandbox: invalid or overbroad permissions")

    # Maintainer scripts belong to control.tar.*, never the installed data tree.
    if control_arg is None:
        failures += 1
        print("FAIL control archive root not supplied; postinst was not verified")
    else:
        postinst = pathlib.Path(control_arg) / "postinst"
        original = layout / "DEBIAN/postinst"
        if not postinst.is_file():
            failures += 1
            print("FAIL postinst is missing from the control archive")
        elif postinst.read_bytes() != original.read_bytes():
            failures += 1
            print("FAIL packaged postinst differs from the reviewed script")
        elif postinst.stat().st_mode & 0o777 != 0o755:
            failures += 1
            print("FAIL packaged postinst mode must be 0755")
        else:
            print("OK   control archive postinst: reviewed content, mode 0755")
    if (root / "DEBIAN").exists():
        failures += 1
        print("FAIL DEBIAN metadata leaked into the installed data archive")

    rootless_prefix = root / "var" / "jb"
    if failures and rootless_prefix.is_dir():
        print(
            "\nHINT: package contains var/jb; this reconstruction targets the "
            "recovered rootful install paths."
        )

    print(f"\n{len(expected)} required data files plus postinst checked, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "pkg",
                  sys.argv[2] if len(sys.argv) > 2 else None))
