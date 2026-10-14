#!/usr/bin/env python3
"""Run the production postinst control flow with only filesystem/tool paths
redirected to a temporary fixture. Never executes real launchctl or a daemon.
"""
from pathlib import Path
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def unix_path(path):
    value = str(path).replace("\\", "/")
    if os.name == "nt" and len(value) > 2 and value[1] == ":":
        return "/" + value[0].lower() + value[2:]
    return value

def main():
    shell = sys.argv[1] if len(sys.argv) > 1 else shutil.which("sh")
    assert shell, "Specify a POSIX shell; no native launchctl will be used"
    source = (ROOT / "layout/DEBIAN/postinst").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="crane-postinst-") as temp:
        fixture = Path(temp)
        tools = fixture / "bin"
        tools.mkdir()
        fake_id = tools / "id"
        fake_id.write_text('#!/bin/sh\nprintf "%s\\n" "$CASE_UID"\n', encoding="utf-8")
        launchctl = tools / "launchctl"
        launchctl.write_text("""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$CASE_LOG"
case "$1" in
    print)
        [ "$*" = 'print system/com.opa334.cranehelperd' ] || exit 98
        [ -f "$CASE_STATE" ]
        ;;
    bootstrap)
        [ "$2" = system ] && [ "$3" = "$CASE_PLIST" ] || exit 98
        [ "$CASE_MODE" != bootstrap_fail ] || exit 73
        : > "$CASE_STATE"
        [ "$CASE_MODE" != race ] || exit 73
        ;;
    kickstart)
        [ "$*" = 'kickstart -k system/com.opa334.cranehelperd' ] || exit 98
        [ -f "$CASE_STATE" ] || exit 97
        [ "$CASE_MODE" != kickstart_fail ] || exit 9
        ;;
    *) exit 99 ;;
esac
""", encoding="utf-8")
        for p in (fake_id, launchctl):
            p.chmod(0o755)
        plist = fixture / "job.plist"
        binary = fixture / "helper"
        # No daemon is run; file presence/execute-bit tests use this inert fixture.
        plist.write_text("fixture", encoding="utf-8")
        binary.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
        binary.chmod(0o755)
        replacements = {
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin":
                "PATH=" + shlex.quote(unix_path(tools) + ":/usr/bin:/bin:/usr/sbin:/sbin"),
            "plist=/Library/LaunchDaemons/com.opa334.cranehelperd.plist":
                "plist=" + shlex.quote(unix_path(plist)),
            "binary=/usr/local/libexec/cranehelperd":
                "binary=" + shlex.quote(unix_path(binary)),
            "launchctl=/bin/launchctl":
                "launchctl=" + shlex.quote(unix_path(launchctl)),
        }
        for old, new in replacements.items():
            assert source.count(old) == 1, old
            source = source.replace(old, new)
        assert "launchctl=/bin/launchctl" not in source
        script = fixture / "postinst"
        script.write_text(source, encoding="utf-8")
        subprocess.run([shell, "-n", str(script)], check=True)
        state = fixture / "registered"
        log = fixture / "commands"
        print_job = "print system/com.opa334.cranehelperd"
        bootstrap = "bootstrap system " + unix_path(plist)
        kickstart = "kickstart -k system/com.opa334.cranehelperd"
        cases = [
            ("fresh", False, "0", "configure", True, 0, [print_job, bootstrap, kickstart, print_job]),
            ("registered", True, "0", "configure", True, 0, [print_job, kickstart, print_job]),
            ("race", False, "0", "configure", True, 0, [print_job, bootstrap, print_job, kickstart, print_job]),
            ("bootstrap_fail", False, "0", "configure", True, 1, [print_job, bootstrap, print_job]),
            ("kickstart_fail", True, "0", "configure", True, 9, [print_job, kickstart]),
            ("nonroot", False, "501", "configure", True, 1, []),
            ("missing_files", False, "0", "configure", False, 1, []),
            ("ignored_action", False, "0", "abort-upgrade", True, 0, []),
        ]
        for mode, registered, uid, action, files, expected_exit, expected_calls in cases:
            if state.exists(): state.unlink()
            if log.exists(): log.unlink()
            if registered: state.touch()
            if files: plist.write_text("fixture", encoding="utf-8")
            elif plist.exists(): plist.unlink()
            env = dict(os.environ, CASE_MODE=mode, CASE_UID=uid,
                       CASE_STATE=unix_path(state), CASE_LOG=unix_path(log),
                       CASE_PLIST=unix_path(plist))
            result = subprocess.run([shell, str(script), action], env=env,
                                    capture_output=True, text=True, timeout=10)
            calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
            assert result.returncode == expected_exit, (mode, result.returncode, result.stderr)
            assert calls == expected_calls, (mode, calls, expected_calls)
            notice = "helper ready; daemon injection verification/fix-up is handled at runtime"
            assert (notice in result.stdout) == (action == "configure" and expected_exit == 0), (mode, result.stdout)
            assert "Reboot Userspace" not in result.stdout, (mode, result.stdout)
            print(f"postinst fixture {mode}: PASS")
    print("postinst control-flow smoke: PASS (mock launchctl only; device unverified)")

if __name__ == "__main__":
    main()
