#!/bin/bash
# uninstall-xcode.sh — Deep removal of Xcode CLT and/or Xcode.app
# Removes CLT, Xcode.app, developer dirs, caches, receipts, xcode-select path
# Must be run as root (sudo ./uninstall-xcode.sh)

set -euo pipefail

AUTOBREW_LOG="/var/log/autobrew.log"

log() { echo "[xcode-uninstall] $*"; echo "[xcode-uninstall] $*" >> "${AUTOBREW_LOG}"; }
log "=== Xcode Uninstaller started at $(date) ==="

# ---------------------------------------------------------------------------
# Arg parsing (--username / -u, --password / -p, --full / -f)
# --full also removes Xcode.app (skipped by default if only CLT is installed)
# ---------------------------------------------------------------------------

TargetUser=$(echo "show State:/Users/ConsoleUser" | \
    scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }')
Password=""
REMOVE_XCODE_APP=0

_args=("$0" "$@")
_i=0
while [ "${_i}" -lt "${#_args[@]}" ]; do
    case "${_args[${_i}]}" in
        --username|-u) _i=$((_i + 1)); [ "${_i}" -lt "${#_args[@]}" ] && TargetUser="${_args[${_i}]}" ;;
        --password|-p) _i=$((_i + 1)); [ "${_i}" -lt "${#_args[@]}" ] && Password="${_args[${_i}]}" ;;
        --full|-f) REMOVE_XCODE_APP=1 ;;
    esac
    _i=$((_i + 1))
done
unset _i _args

# Legacy positional fallback (Jamf $3 / direct $1)
if [ -z "${TargetUser}" ]; then
    if [ -n "${3:-}" ] && [[ "$3" != -* ]]; then
        TargetUser="$3"
    elif [ -n "${1:-}" ] && [[ "$1" != -* ]]; then
        TargetUser="$1"
    fi
fi

if [ -z "${TargetUser}" ]; then
    log "ERROR: 'TargetUser' is empty. Specify a user with --username <user>."
    exit 1
fi

if /usr/bin/dscl . -read "/Users/${TargetUser}" >/dev/null 2>&1; then
    log "Validated user: ${TargetUser}"
else
    log "ERROR: Specified user \"${TargetUser}\" is invalid."
    exit 1
fi

USER_HOME=$(dscl . -read "/Users/${TargetUser}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -z "${USER_HOME}" ] && USER_HOME="/Users/${TargetUser}"

# Detect what is actually installed
HAS_CLT=0
HAS_XCODEAPP=0
[ -d "/Library/Developer/CommandLineTools" ] && HAS_CLT=1
[ -d "/Applications/Xcode.app" ]             && HAS_XCODEAPP=1

if [ "${HAS_CLT}" -eq 0 ] && [ "${HAS_XCODEAPP}" -eq 0 ]; then
    log "Neither Xcode CLT nor Xcode.app found. Nothing to remove."
    exit 0
fi

log "Target user  : ${TargetUser}"
log "User home    : ${USER_HOME}"
log "CLT present  : ${HAS_CLT}"
log "Xcode.app    : ${HAS_XCODEAPP}"
log "Remove --full: ${REMOVE_XCODE_APP}"

# ─── Step 1: Reset xcode-select ──────────────────────────────────────────────
log "--- Step 1: Resetting xcode-select developer path ---"
if /usr/bin/xcode-select -p >/dev/null 2>&1; then
    /usr/bin/xcode-select -r 2>/dev/null || true
    log "xcode-select path reset."
else
    log "xcode-select had no active path."
fi

# ─── Step 2: Xcode.app (only with --full flag) ────────────────────────────────
if [ "${HAS_XCODEAPP}" -eq 1 ] && [ "${REMOVE_XCODE_APP}" -eq 1 ]; then
    log "--- Step 2: Removing /Applications/Xcode.app ---"
    # Quit Xcode if running
    TUID=$(id -u "${TargetUser}" 2>/dev/null || true)
    if [ -n "${TUID}" ]; then
        launchctl asuser "${TUID}" osascript \
            -e 'tell application "Xcode" to quit' 2>/dev/null || true
    fi
    rm -rf /Applications/Xcode.app
    log "Removed /Applications/Xcode.app"
elif [ "${HAS_XCODEAPP}" -eq 1 ] && [ "${REMOVE_XCODE_APP}" -eq 0 ]; then
    log "--- Step 2: Skipping Xcode.app (pass --full to remove it) ---"
fi

# ─── Step 3: Command Line Tools directory ────────────────────────────────────
log "--- Step 3: Removing Xcode Command Line Tools ---"
if [ -d "/Library/Developer/CommandLineTools" ]; then
    rm -rf /Library/Developer/CommandLineTools
    log "Removed /Library/Developer/CommandLineTools"
fi
# Remove /Library/Developer if now empty
rmdir /Library/Developer 2>/dev/null && log "Removed empty /Library/Developer" || true

# ─── Step 4: PKG receipts ────────────────────────────────────────────────────
log "--- Step 4: Forgetting pkg receipts ---"
for _pkg in $(pkgutil --pkgs 2>/dev/null | grep -E \
    'com\.apple\.pkg\.(CLTools|DeveloperToolsCLI|XcodeExtensionSupport|Xcode|MobileDevice|CoreSimulator)' \
    || true); do
    pkgutil --forget "${_pkg}" 2>/dev/null && log "Forgot receipt: ${_pkg}" || true
done
unset _pkg

# ─── Step 5: System-level developer caches ───────────────────────────────────
log "--- Step 5: Removing system-level developer caches ---"
for _path in \
    /Library/Caches/com.apple.dt.Xcode \
    /Library/Caches/com.apple.clt.git \
    /var/folders; do
    # /var/folders contains per-UID temp caches — only target known Xcode subdirs
    if [ "${_path}" = "/var/folders" ]; then
        find /var/folders -maxdepth 4 -name "com.apple.dt.*" -exec rm -rf {} + 2>/dev/null || true
        log "Cleaned com.apple.dt.* entries under /var/folders"
    elif [ -e "${_path}" ]; then
        rm -rf "${_path}" && log "Removed ${_path}"
    fi
done
unset _path

# ─── Step 6: User-level Xcode data ───────────────────────────────────────────
log "--- Step 6: Removing user-level Xcode data ---"
for _path in \
    "${USER_HOME}/Library/Developer/Xcode" \
    "${USER_HOME}/Library/Developer/CoreSimulator" \
    "${USER_HOME}/Library/Developer/XCTestDevices" \
    "${USER_HOME}/Library/Application Support/Xcode" \
    "${USER_HOME}/Library/Caches/com.apple.dt.Xcode" \
    "${USER_HOME}/Library/Caches/com.apple.dt.instruments" \
    "${USER_HOME}/Library/Logs/CoreSimulator" \
    "${USER_HOME}/Library/Logs/Xcode" \
    "${USER_HOME}/Library/Preferences/com.apple.dt.Xcode.plist" \
    "${USER_HOME}/Library/Saved Application State/com.apple.dt.Xcode.savedState" \
    "${USER_HOME}/.xcode-select"; do
    if [ -e "${_path}" ]; then
        rm -rf "${_path}" && log "Removed ${_path}"
    fi
done
unset _path

# Remove ~/Library/Developer if now empty (leave it if other tools use it)
rmdir "${USER_HOME}/Library/Developer" 2>/dev/null \
    && log "Removed empty ${USER_HOME}/Library/Developer" || true

# ─── Step 7: Mobile device support (large disk hogs) ─────────────────────────
log "--- Step 7: Removing MobileDevice support files ---"
for _path in \
    /Library/MobileDevice \
    "${USER_HOME}/Library/MobileDevice"; do
    if [ -e "${_path}" ]; then
        rm -rf "${_path}" && log "Removed ${_path}"
    fi
done
unset _path

# ─── Step 8: Launchd services ─────────────────────────────────────────────────
log "--- Step 8: Removing Xcode / CoreSimulator launchd services ---"
TUID=$(id -u "${TargetUser}" 2>/dev/null || true)

for _plist in \
    "${USER_HOME}/Library/LaunchAgents/com.apple.CoreSimulator"*.plist \
    "${USER_HOME}/Library/LaunchAgents/com.apple.dt."*.plist; do
    [ -f "${_plist}" ] || continue
    [ -n "${TUID}" ] && launchctl asuser "${TUID}" launchctl unload "${_plist}" 2>/dev/null || true
    rm -f "${_plist}" && log "Removed LaunchAgent: ${_plist}"
done

for _plist in \
    /Library/LaunchDaemons/com.apple.CoreSimulator*.plist \
    /Library/LaunchDaemons/com.apple.dt.*.plist; do
    [ -f "${_plist}" ] || continue
    launchctl unload "${_plist}" 2>/dev/null || true
    rm -f "${_plist}" && log "Removed LaunchDaemon: ${_plist}"
done
unset _plist TUID

# ─── Step 9: Leftover temp/sentinel files ────────────────────────────────────
log "--- Step 9: Removing temp and sentinel files ---"
rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress 2>/dev/null && \
    log "Removed CLT sentinel file" || true

unset Password

# ─── Verification ─────────────────────────────────────────────────────────────
log "--- Verification ---"
_remaining=0

[ -d "/Library/Developer/CommandLineTools" ] && \
    log "WARNING: /Library/Developer/CommandLineTools still present" && _remaining=1
[ "${REMOVE_XCODE_APP}" -eq 1 ] && [ -d "/Applications/Xcode.app" ] && \
    log "WARNING: /Applications/Xcode.app still present" && _remaining=1
/usr/bin/xcode-select -p >/dev/null 2>&1 && \
    log "WARNING: xcode-select still points to $(xcode-select -p)" && _remaining=1

if [ "${_remaining}" -eq 0 ]; then
    log "Xcode has been successfully removed from this system."
    log "=== Xcode Uninstaller finished successfully at $(date) ==="
    exit 0
else
    log "Some Xcode files may still remain — manual inspection recommended."
    log "=== Xcode Uninstaller finished with warnings at $(date) ==="
    exit 1
fi
