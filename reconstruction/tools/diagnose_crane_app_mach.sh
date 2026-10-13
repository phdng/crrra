#!/bin/sh
# Read-only, mobile-shell Crane app-runtime Mach/XPC diagnosis.
# This script does not perform launchd changes, modify sandbox policy,
# restart Chrome, open private app data, or touch profiles.
set -u
lib='/Library/MobileSubstrate/DynamicLibraries/ Crane.dylib'
profile='/Library/libSandy/CraneAppRuntime.plist'
printf 'Crane app-to-helper Mach access (read-only; uid=%s)\n' "$(id -u)"
resolve() {
    file="$1"
    if [ -f "$file" ]; then
        printf '%s' "$file"
    elif command -v jbroot >/dev/null 2>&1; then
        mapped="$(jbroot "$file" 2>/dev/null || true)"
        if [ -n "$mapped" ] && [ -f "$mapped" ]; then
            printf '%s' "$mapped"
        fi
    fi
}
image="$(resolve "$lib")"
granted="$(resolve "$profile")"
printf '\n=== Installed app dylib ===\n'
if [ -n "$image" ]; then
    ls -l "$image"
    if command -v strings >/dev/null 2>&1; then
        if strings "$image" 2>/dev/null | grep -F 'APP_RUNTIME_MACH_DIAGNOSTIC_V2'; then
            printf 'MARKER: new app Mach diagnostics present in on-disk dylib.\n'
        else
            printf 'MARKER: absent. Installed dylib may be an older build.\n'
        fi
    else
        printf 'MARKER: cannot inspect; strings is not installed.\n'
    fi
else
    printf 'Dylib not visible/readable to mobile: %s\n' "$lib"
fi
printf '\n=== App Mach profile ===\n'
if [ -n "$granted" ]; then
    ls -l "$granted"
    if command -v plutil >/dev/null 2>&1; then
        plutil -p "$granted" 2>/dev/null || true
    fi
else
    printf 'Profile not visible/readable to mobile: %s\n' "$profile"
fi
printf '\n=== Next Chrome launch: observe app runtime profile outcome ===\n'
printf '%s\n' "oslog | grep -E 'Crane: app runtime Mach profile|Crane: app runtime_report|Crane: helper runtime_report error|Crane helper: (runtime_report|lookup_pid)|CraneSB: post-launch'"
printf 'A profile file or binary marker alone does NOT establish a successful sandbox grant.\n'
printf 'Success needs profile status=0, app ping compatible, and same-PID Helper proof.\n'
