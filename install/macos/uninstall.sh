#!/bin/bash
# Removes the SteadyVolume LaunchDaemon. Must be run with sudo.
#
#   steadyvol unprotect            # password required
#   sudo ./uninstall.sh [--keep-config]
#
# Refuses to run while tamper protection is on. Root can always remove the daemon by hand
# (see the README); this check stops accidents, it is not a security boundary.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this script with sudo: sudo $0 $*" >&2
    exit 1
fi

LABEL="com.steadyvolume.daemon"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
CONFIG_DIR="/Library/Application Support/SteadyVolume"
CONFIG="$CONFIG_DIR/config.json"
KEEP_CONFIG=0
for arg in "$@"; do
    case "$arg" in
        --keep-config) KEEP_CONFIG=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "Unknown option $arg" >&2; exit 2 ;;
    esac
done

if [[ -f "$CONFIG" ]] && [[ "$(plutil -extract protected raw -o - "$CONFIG" 2>/dev/null || echo false)" == "true" ]]; then
    echo "Tamper protection is on. Run 'steadyvol unprotect' (password required) first." >&2
    exit 1
fi

is_loaded() { launchctl print "system/${LABEL}" >/dev/null 2>&1; }

# bootout can itself report "Input/output error" (5) while still unloading the job, so do not stop
# on its exit code: try by label, then by plist path, and wait for the job to go away.
if is_loaded; then
    launchctl bootout "system/${LABEL}" 2>/dev/null || launchctl bootout system "$PLIST" 2>/dev/null || true
    for _ in $(seq 1 25); do
        is_loaded || break
        sleep 0.2
    done
fi
rm -f "$PLIST" /usr/local/bin/steadyvol /var/run/steadyvolume.sock
rm -rf /usr/local/libexec/steadyvolume
if [[ "$KEEP_CONFIG" -eq 0 ]]; then
    rm -rf "$CONFIG_DIR"
else
    echo "Kept $CONFIG_DIR (password and lock settings)."
fi

if is_loaded; then
    echo "The daemon is still loaded. Run: sudo launchctl bootout system/${LABEL}" >&2
    exit 1
fi
echo "SteadyVolume has been uninstalled."
