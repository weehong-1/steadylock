#!/bin/bash
# Installs the SteadyVolume LaunchDaemon. Must be run with sudo.
#
#   sudo bash ./install.sh [SOURCE_DIR]     (bash: a downloaded zip may drop the executable bit)
#
# SOURCE_DIR holds steadyvolumed, steadyvol and com.steadyvolume.daemon.plist (the CI artifact
# layout). Without it, the script looks next to itself, then in the repo's universal release build
# (macos/.build/out/Products/Release, from: cd macos && swift build -c release --arch arm64 --arch x86_64).
#
# Before installing, it runs the daemon's read-only probe as root (nothing is written to the audio
# system) and stops if root cannot see and read the output devices. --skip-probe skips that check.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this script with sudo: sudo $0 $*" >&2
    exit 1
fi

LABEL="com.steadyvolume.daemon"
LIBEXEC="/usr/local/libexec/steadyvolume"
BIN="/usr/local/bin"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
CONFIG_DIR="/Library/Application Support/SteadyVolume"
CONFIG="$CONFIG_DIR/config.json"
SOCKET="/var/run/steadyvolume.sock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || true)"

SKIP_PROBE=0
SOURCE_DIR=""
BOOTSTRAP_ERROR=""
for arg in "$@"; do
    case "$arg" in
        --skip-probe) SKIP_PROBE=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        -*) echo "Unknown option $arg" >&2; exit 2 ;;
        *) SOURCE_DIR="$arg" ;;
    esac
done

find_file() { # name, candidate dirs...
    local name="$1"; shift
    for dir in "$@"; do
        [[ -n "$dir" && -f "$dir/$name" ]] && { echo "$dir/$name"; return 0; }
    done
    return 1
}

CANDIDATES=("$SOURCE_DIR" "$SCRIPT_DIR" "$REPO_DIR/macos/.build/out/Products/Release" "$REPO_DIR/macos/.build/release")
if [[ -n "$SOURCE_DIR" ]]; then CANDIDATES=("$SOURCE_DIR"); fi
DAEMON_SRC="$(find_file steadyvolumed "${CANDIDATES[@]}")" || { echo "steadyvolumed not found. Build it first: cd macos && swift build -c release --arch arm64 --arch x86_64" >&2; exit 1; }
CLI_SRC="$(find_file steadyvol "$(dirname "$DAEMON_SRC")")" || { echo "steadyvol not found next to $DAEMON_SRC" >&2; exit 1; }
PLIST_SRC="$(find_file "${LABEL}.plist" "$(dirname "$DAEMON_SRC")" "$SCRIPT_DIR" "$REPO_DIR/macos/Resources")" || { echo "${LABEL}.plist not found" >&2; exit 1; }

is_loaded() { launchctl print "system/${LABEL}" >/dev/null 2>&1; }
is_protected() {
    [[ -f "$CONFIG" ]] && [[ "$(plutil -extract protected raw -o - "$CONFIG" 2>/dev/null || echo false)" == "true" ]]
}

if is_loaded; then
    if is_protected; then
        echo "SteadyVolume is already installed. Run 'steadyvol unprotect', then uninstall.sh, then install again." >&2
    else
        echo "SteadyVolume is already installed. Run uninstall.sh (add --keep-config to keep the password), then install again." >&2
    fi
    exit 1
fi
if [[ -e "$PLIST" ]]; then
    if is_protected; then
        echo "SteadyVolume is installed with tamper protection on, but its daemon is not loaded." >&2
        echo "Load it again with: sudo launchctl bootstrap system $PLIST" >&2
        echo "Then run 'steadyvol unprotect' and uninstall.sh before installing again." >&2
        exit 1
    fi
    # Not loaded and not protected: what is left of an earlier install that did not finish (for
    # example a failed launchctl bootstrap). Replace it. An existing config.json is kept.
    echo "Replacing an earlier SteadyVolume install that is not loaded."
    rm -f "$PLIST"
fi

plutil -lint "$PLIST_SRC" >/dev/null
echo "Installing from $(dirname "$DAEMON_SRC")"

# Stage root-owned copies. Files from a downloaded zip (CI artifact or release) may have lost their
# executable bit and carry a quarantine flag that makes Gatekeeper refuse to run unsigned binaries.
STAGE="$(mktemp -d /tmp/steadyvolume-install.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
install -o root -g wheel -m 755 "$DAEMON_SRC" "$STAGE/steadyvolumed"
install -o root -g wheel -m 755 "$CLI_SRC" "$STAGE/steadyvol"
install -o root -g wheel -m 644 "$PLIST_SRC" "$STAGE/${LABEL}.plist"

# Remove the download quarantine flag by name. A plain `xattr -c` can stop at an attribute macOS
# protects (com.apple.macl, com.apple.provenance) and leave the quarantine flag in place. A
# quarantined, unsigned binary is refused by Gatekeeper ("Apple could not verify ...") and launchd
# then fails to load the daemon ("Bootstrap failed: 5: Input/output error").
unquarantine() { # files...
    local f
    for f in "$@"; do
        xattr -d com.apple.quarantine "$f" 2>/dev/null || true
        xattr -c "$f" 2>/dev/null || true
        if xattr -p com.apple.quarantine "$f" >/dev/null 2>&1; then
            echo "Could not remove the download quarantine flag from $f." >&2
            echo "Run: sudo xattr -dr com.apple.quarantine \"$ORIGINAL_DIR\"   then run this script again." >&2
            exit 1
        fi
    done
}
# Re-sign the binaries locally (ad hoc). This replaces a signature damaged in transit and lets
# Apple silicon run them; it gives them no more trust than a local build.
adhoc_sign() { # files...
    local f
    for f in "$@"; do
        codesign --force --sign - "$f" >/dev/null 2>&1 || echo "Warning: could not re-sign $f (codesign failed)." >&2
    done
}
ORIGINAL_DIR="$(dirname "$DAEMON_SRC")"
unquarantine "$STAGE"/*
adhoc_sign "$STAGE/steadyvolumed" "$STAGE/steadyvol"
DAEMON_SRC="$STAGE/steadyvolumed"
CLI_SRC="$STAGE/steadyvol"
PLIST_SRC="$STAGE/${LABEL}.plist"

"$DAEMON_SRC" --version >/dev/null || { echo "steadyvolumed does not run on this Mac." >&2; exit 1; }

if [[ "$SKIP_PROBE" -eq 0 ]]; then
    echo
    echo "Checking that root can see and read the output devices (read-only probe; nothing is written)..."
    if ! "$DAEMON_SRC" --probe; then
        echo "The probe failed, so the daemon would not be able to lock the volume as root. Nothing was installed." >&2
        exit 1
    fi
    echo
fi

# Binaries and plist: owned by root:wheel and not writable by anyone else.
install -d -o root -g wheel -m 755 "$LIBEXEC"
install -d -o root -g wheel -m 755 "$BIN"
install -o root -g wheel -m 755 "$DAEMON_SRC" "$LIBEXEC/steadyvolumed"
install -o root -g wheel -m 755 "$CLI_SRC" "$BIN/steadyvol"
install -o root -g wheel -m 644 "$PLIST_SRC" "$PLIST"
# Make sure no quarantine flag came along with the copy.
unquarantine "$LIBEXEC/steadyvolumed" "$BIN/steadyvol" "$PLIST"

# Config directory: root only. The daemon creates config.json in it (mode 600).
install -d -o root -g wheel -m 700 "$CONFIG_DIR"

wait_unloaded() { # up to ~5 s
    for _ in $(seq 1 25); do
        is_loaded || return 0
        sleep 0.2
    done
    return 1
}

# Puts the system back as it was before this script ran, apart from a config.json kept from before.
rollback() {
    launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
    rm -f "$PLIST" "$BIN/steadyvol"
    rm -rf "$LIBEXEC"
    rmdir "$CONFIG_DIR" 2>/dev/null || true
}

# "Bootstrap failed: 5: Input/output error" is launchd's catch-all error. Known causes: a stale
# registration of the label that launchd is still tearing down, the job being disabled (launchctl or
# Login Items), or launchd being briefly busy right after the plist appears. Clear what can be
# cleared and try a few times before giving up.
bootstrap_daemon() {
    local attempt
    for attempt in 1 2 3; do
        launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
        wait_unloaded || true
        launchctl enable "system/${LABEL}" 2>/dev/null || true
        if BOOTSTRAP_ERROR="$(launchctl bootstrap system "$PLIST" 2>&1)"; then
            return 0
        fi
        # launchd sometimes reports an error although the job did load.
        if is_loaded; then
            return 0
        fi
        echo "launchctl bootstrap attempt $attempt failed: ${BOOTSTRAP_ERROR}" >&2
        sleep "$attempt"
    done
    return 1
}

print_bootstrap_diagnostics() {
    echo >&2
    echo "Could not load the SteadyVolume daemon: ${BOOTSTRAP_ERROR}" >&2
    echo "Details:" >&2
    ls -l@ "$PLIST" "$LIBEXEC/steadyvolumed" >&2 2>/dev/null || true
    plutil -lint "$PLIST" >&2 || true
    xattr -l "$LIBEXEC/steadyvolumed" >&2 2>/dev/null || true
    codesign --verify --verbose "$LIBEXEC/steadyvolumed" >&2 2>&1 || true
    if launchctl print-disabled system 2>/dev/null | grep -F "\"${LABEL}\"" >&2; then
        echo "  (launchd lists the job above; '=> disabled' or '=> true' means it is turned off)" >&2
    fi
    /usr/bin/log show --last 2m --style compact \
        --predicate "process == \"launchd\" AND eventMessage CONTAINS \"${LABEL}\"" 2>/dev/null | tail -n 15 >&2 || true
    echo >&2
    echo "Things to check:" >&2
    echo "  * If macOS said \"Apple could not verify ...\": open System Settings > Privacy & Security," >&2
    echo "    click Open Anyway next to the steadyvol or steadyvolumed message, then run this script again." >&2
    echo "  * System Settings > General > Login Items & Extensions > Allow in the Background:" >&2
    echo "    make sure steadyvolumed is switched on, then run this script again." >&2
    echo "  * 'sudo sfltool dumpbtm | grep -i -A5 steadyvolume' shows whether macOS blocked it." >&2
    echo "  * Restarting the Mac clears a registration that launchd is stuck on." >&2
}

if ! bootstrap_daemon; then
    print_bootstrap_diagnostics
    rollback
    echo "Nothing was left installed. Fix the cause above and run this script again." >&2
    exit 1
fi

for _ in $(seq 1 50); do
    [[ -S "$SOCKET" ]] && break
    sleep 0.2
done
if [[ ! -S "$SOCKET" ]]; then
    echo "The daemon did not open $SOCKET. Check: /usr/bin/log show --predicate 'subsystem == \"com.steadyvolume\"' --last 5m" >&2
    exit 1
fi

echo
echo "First-run setup: choose the SteadyVolume password."
"$BIN/steadyvol" setup || echo "Setup did not complete. Run 'steadyvol setup' as soon as possible." >&2

echo
"$BIN/steadyvol" status || true
echo
echo "SteadyVolume is installed but not locked yet."
echo "  Lock every output device at its current level:  steadyvol lock"
echo "  Lock every output device at one level:          steadyvol lock 30"
