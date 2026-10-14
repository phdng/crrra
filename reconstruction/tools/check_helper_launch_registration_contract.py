"""Source/package contract for the Crane helper launchd job.

The selected Mach service com.opa334.cranehelperd.xpc is advertised by
launchd job label com.opa334.cranehelperd (a different string). The app's
cranehelperd_start only kickstarts an already registered job; it does NOT
bootstrap a newly installed LaunchDaemon. This test verifies the recovered
binary plist, installed executable layout, diagnostic-only script and CI
artifact checks, including the user-authorized package configure adapter.
This check does not execute a real privileged installer or change launchd.

Native Theos/package install and root iOS launchctl output are separate.
"""
from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
layout = root / "layout/Library/LaunchDaemons/com.opa334.cranehelperd.plist"
job = plistlib.loads(layout.read_bytes())

assert job["Label"] == "com.opa334.cranehelperd"
assert job["Program"] == "/usr/local/libexec/cranehelperd"
assert job["UserName"] == "root"
assert job["RunAtLoad"] is True
assert job["KeepAlive"] is True
assert job["MachServices"] == {
    "com.opa334.cranehelperd.preferences.xpc": True,
    "com.opa334.cranehelperd.xpc": True,
}

paths = (root / "sources/common/CRPaths.h").read_text()
assert '#define CR_HELPERD_MACH_SERVICE         @"com.opa334.cranehelperd.xpc"' in paths

daemon_mk = (root / "sources/cranehelperd/Makefile").read_text()
assert "TOOL_NAME = cranehelperd" in daemon_mk
assert "cranehelperd_INSTALL_PATH = /usr/local/libexec" in daemon_mk

starter = (root / "sources/cranehelperd_start/cranehelperd_start.m").read_text()
assert '(char *)"kickstart"' in starter
assert '(char *)"system/com.opa334.cranehelperd"' in starter
assert '(char *)"bootstrap"' not in starter, "Do not silently enable privileged service registration"
assert 'jbroot("/bin/launchctl")' in starter

diagnostic = (root / "tools/diagnose_cranehelperd.sh").read_text()
for phrase in (
    'label=com.opa334.cranehelperd',
    'launchctl print "system/$label"',
    "ps -A | grep '[c]ranehelperd'",
    'jbroot "$plist"',
    'jbroot "$binary"',
    'PLIST PRESENT:',
    'EXECUTABLE PRESENT:',
    'EXE',
    'No cranehelperd process observed',
    'never have been bootstrapped',
    'MODE: mobile/non-root.',
    'a failed launchctl print does NOT prove the job is absent.',
    'Mobile-only result: no conclusion about system launchd registration.',
    'the mobile shell cannot bootstrap the system job.',
    'PLIST NOT VISIBLE:',
    'EXECUTABLE NOT VISIBLE:',
    "dpkg-query -W -f='${Status} | ${Architecture} | ${Version}",
    'dpkg install status does not establish launchd job registration.',
):
    assert phrase in diagnostic, phrase
for forbidden in ('launchctl bootstrap system ', 'launchctl kickstart ', 'launchctl bootout '):
    assert forbidden not in diagnostic, "Device diagnostic must remain read-only"
assert diagnostic.startswith("#!/bin/sh\n")

verifier = (root / "tools/verify_package_layout.py").read_text()
assert '"usr/local/libexec/cranehelperd"' in verifier
assert '(layout.rglob("*"))' in verifier or 'layout.rglob("*")' in verifier
for needle in (
    'plistlib.loads(plist_path.read_bytes())',
    'job.get("Label") == "com.opa334.cranehelperd"',
    'job.get("Program") == "/usr/local/libexec/cranehelperd"',
    'job.get("MachServices") == {',
    'helper_path.stat().st_mode',
    'stat.S_IXUSR',
    'failures += 1',
):
    assert needle in verifier, needle
workflow = (root.parent / ".github/workflows/build.yml").read_text()
assert "tools/verify_package_layout.py" in workflow
assert "check_helper_launch_registration_contract.py" in workflow
assert "sh -n reconstruction/tools/diagnose_cranehelperd.sh" in workflow

postinst = (root / "layout/DEBIAN/postinst").read_text()
for needle in (
    'case "${1:-}" in',
    'configure)',
    'service=system/com.opa334.cranehelperd',
    'plist=/Library/LaunchDaemons/com.opa334.cranehelperd.plist',
    'binary=/usr/local/libexec/cranehelperd',
    'launchctl=/bin/launchctl',
    'if [ "$(id -u)" != 0 ]; then',
    'if ! "$launchctl" print "$service"',
    '"$launchctl" bootstrap system "$plist"',
    '"$launchctl" kickstart -k "$service"',
    'if [ ! -f "$plist" ] || [ ! -f "$binary" ] || [ ! -x "$binary" ]; then',
):
    assert needle in postinst, needle
assert postinst.splitlines()[0] == "#!/bin/sh"
assert "helper ready; daemon injection verification/fix-up is handled at runtime" in postinst
assert "runInjectionFixUpIfNeededAndReply:" in postinst
assert "Reboot Userspace" not in postinst
assert "Respring alone is not sufficient" not in postinst
assert "bootout" not in postinst
assert "killall" not in postinst
assert "rm " not in postinst
make = (root / "Makefile").read_text()
assert 'before-package:: $(THEOS_STAGING_DIR)/DEBIAN' in make
assert 'chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"' in make
assert 'p.relative_to(layout).parts[0] != "DEBIAN"' in verifier
assert "postinst.stat().st_mode & 0o777 != 0o755" in verifier
assert "tools/verify_package_layout.py pkg pkg-control" in workflow
assert "helper_postinst_smoke.py" in workflow
print("Crane helper launchd registration/layout contract: PASS (device unverified)")
