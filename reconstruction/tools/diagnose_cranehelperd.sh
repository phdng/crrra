#!/bin/sh
# Read-only Crane helper launchd diagnostic for mobile or root shells.
# Never bootstraps, kickstarts, removes, or modifies another launchd job.
set -u

label=com.opa334.cranehelperd
plist=/Library/LaunchDaemons/com.opa334.cranehelperd.plist
binary=/usr/local/libexec/cranehelperd
printf 'Crane helper launchd diagnostics (read-only)\n'
current_uid="$(id -u)"
printf 'uid=%s  label=%s\n' "$current_uid" "$label"

if [ "$current_uid" != 0 ]; then
    printf 'MODE: mobile/non-root. System launchd state may be inaccessible;\n'
    printf 'a failed launchctl print does NOT prove the job is absent.\n'
    printf 'No root login or privilege escalation is required for this diagnostic.\n'
fi

if command -v launchctl >/dev/null 2>&1; then
    printf '\n=== launchctl system job ===\n'
    if launchctl print "system/$label"; then
        printf 'RESULT: job is registered; inspect its state, PID and last exit code above.\n'
    else
        printf 'RESULT: INCONCLUSIVE: job not visible (absent OR insufficient privileges).\n'
    fi
else
    printf 'launchctl not on PATH.\n'
fi

printf '\n=== process ===\n'
if command -v ps >/dev/null 2>&1; then
    ps -A | grep '[c]ranehelperd' || printf 'No cranehelperd process observed (may be restricted).\n'
fi

printf '\n=== installed package (mobile-readable metadata) ===\n'
if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Status} | ${Architecture} | ${Version}\n' \
        com.opa334.cranereconstruction 2>/dev/null || \
        printf 'Package record unavailable through dpkg-query.\n'
else
    printf 'dpkg-query is not available.\n'
fi
printf 'NOTE: dpkg install status does not establish launchd job registration.\n'

printf '\n=== installed plist and executable ===\n'
if command -v jbroot >/dev/null 2>&1; then
    jbplist="$(jbroot "$plist" 2>/dev/null || true)"
    jbbinary="$(jbroot "$binary" 2>/dev/null || true)"
else
    jbplist=
    jbbinary=
fi

found_plist=
found_binary=
for candidate in "$jbplist" "$plist" "/var/jb$plist"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        printf 'PLIST PRESENT: %s\n' "$candidate"
        found_plist=$candidate
        if command -v plutil >/dev/null 2>&1; then
            plutil -p "$candidate" 2>/dev/null || true
        fi
        break
    fi
done
if [ -z "$found_plist" ]; then
    printf 'PLIST NOT VISIBLE: absent, wrong root or unreadable under this account: %s\n' "$plist"
fi

for candidate in "$jbbinary" "$binary" "/var/jb$binary"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        printf 'EXECUTABLE PRESENT: %s\n' "$candidate"
        found_binary=$candidate
        if [ -x "$candidate" ]; then
            printf 'EXECUTABLE BIT: yes\n'
        else
            printf 'EXECUTABLE BIT: no (cannot launch)\n'
        fi
        break
    fi
done
if [ -z "$found_binary" ]; then
    printf 'EXECUTABLE NOT VISIBLE: absent, wrong root or unreadable under this account: %s\n' "$binary"
fi

printf '\n=== interpretation ===\n'
if [ "$current_uid" != 0 ]; then
    printf 'Mobile-only result: no conclusion about system launchd registration.\n'
    if [ -z "$found_plist" ] || [ -z "$found_binary" ]; then
        printf 'Verify installation of the matching Crane package through your package manager.\n'
    else
        printf 'Both files are visible; whether launchd registered the job is still unknown.\n'
    fi
    printf 'If helper remains unavailable, package installation must handle its privileged job lifecycle;\n'
    printf 'the mobile shell cannot bootstrap the system job.\n'
elif [ -n "$found_plist" ] && [ -n "$found_binary" ]; then
    printf 'Both package files exist. If the system job is missing, it may never have been bootstrapped.\n'
    printf 'Inspect system-domain registration and logs before acting on a privileged job.\n'
else
    printf 'Required package files are not visible. Check package installation and permissions.\n'
fi
printf 'This diagnostic does not change launchd state or user container data.\n'
