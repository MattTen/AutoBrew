#!/bin/bash
# xcode-install.sh — Install Xcode Command Line Tools headlessly (no GUI prompts)
# Technique: sentinel file + softwareupdate catalog lookup
# Must be run as root (sudo ./xcode-install.sh)

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[xcode-install] $*"; }

_with_timeout() {
    local _t="$1"; shift
    "$@" &
    local _pid=$!
    ( sleep "${_t}" && kill "${_pid}" 2>/dev/null ) &
    local _w=$!
    wait "${_pid}"
    local _rc=$?
    kill "${_w}" 2>/dev/null
    wait "${_w}" 2>/dev/null
    return "${_rc}"
}

_devtools_ok() {
    /usr/bin/xcode-select -p >/dev/null 2>&1 && return 0
    [ -d "/Library/Developer/CommandLineTools/usr/bin" ] && return 0
    [ -d "/Applications/Xcode.app/Contents/Developer" ] && return 0
    xcrun --find git >/dev/null 2>&1 && return 0
    return 1
}

# ---------------------------------------------------------------------------
# macOS version check (macOS 26.0 / 26.1: CLT not published by Apple yet)
# ---------------------------------------------------------------------------

MACOS_VER=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "${MACOS_VER}" | cut -d. -f1)
MACOS_MINOR=$(echo "${MACOS_VER}" | cut -d. -f2)

if [ "${MACOS_MAJOR}" -ge 26 ] && [ "${MACOS_MINOR:-0}" -lt 2 ]; then
    log "ERROR: CLT unavailable on macOS ${MACOS_VER}."
    log "Apple has not published the CLT to the softwareupdate catalog on this version."
    log "Fix: upgrade to macOS 26.2+, or download CLT manually from https://developer.apple.com/download/all/"
    exit 1
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "Checking Xcode Command Line Tools..."

if _devtools_ok; then
    log "Already installed: $(xcode-select -p)"
    exit 0
fi

# Fix broken xcode-select pointer if the directory is actually present
if [ -d "/Library/Developer/CommandLineTools" ]; then
    log "CLT directory exists but path is broken — fixing pointer..."
    /usr/bin/xcode-select --switch /Library/Developer/CommandLineTools
    if _devtools_ok; then
        log "Fixed. CLT path: $(xcode-select -p)"
        exit 0
    fi
fi

# Full Xcode.app already on disk
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    log "Using installed Xcode.app as developer directory..."
    /usr/bin/xcode-select -s /Applications/Xcode.app
    log "Done: $(xcode-select -p)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Headless install via softwareupdate catalog
# The sentinel file tells softwareupdate to surface CLT packages that are
# otherwise hidden from the normal update list.
# ---------------------------------------------------------------------------

log "Xcode CLT not found — installing via softwareupdate..."

SENTINEL="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
touch "${SENTINEL}"
trap "rm -f '${SENTINEL}'" EXIT

_clt_grep() {
    grep -E 'Command Line Tools' \
    | sed 's/.*Label: //; s/.*\* //' \
    | grep -v '^ *$' \
    | sort -V \
    | tail -1
}

# Try 1: default catalog (works on most Macs)
log "Scanning softwareupdate catalog (attempt 1/3)..."
CLT_PKG=$(_with_timeout 60 softwareupdate -l 2>/dev/null | _clt_grep || true)

# Try 2: --all flag surfaces non-recommended packages (needed on new Macs / macOS 14+)
if [ -z "${CLT_PKG}" ]; then
    log "Scanning with --all flag (attempt 2/3)..."
    CLT_PKG=$(_with_timeout 60 softwareupdate -l --all 2>/dev/null | _clt_grep || true)
fi

# Try 3: as the console user — modern macOS can restrict catalog visibility for root
if [ -z "${CLT_PKG}" ]; then
    CONSOLE_USER=$(echo "show State:/Users/ConsoleUser" | \
        scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }')
    if [ -n "${CONSOLE_USER}" ] && [ "${CONSOLE_USER}" != "root" ]; then
        log "Scanning as console user '${CONSOLE_USER}' (attempt 3/3)..."
        CLT_PKG=$(_with_timeout 60 sudo -n -u "${CONSOLE_USER}" -H \
            softwareupdate -l 2>/dev/null | _clt_grep || true)
    fi
fi

if [ -z "${CLT_PKG}" ]; then
    log "ERROR: No CLT package found in the softwareupdate catalog on macOS ${MACOS_VER}."
    log "Manual option: download from https://developer.apple.com/download/all/"
    exit 1
fi

log "Found package: ${CLT_PKG}"
log "Installing... (this can take several minutes)"

# --agree-to-license suppresses the license agreement window
softwareupdate -i "${CLT_PKG}" --agree-to-license

/usr/bin/xcode-select --switch /Library/Developer/CommandLineTools

if _devtools_ok; then
    log "Xcode Command Line Tools installed successfully: $(xcode-select -p)"
    exit 0
else
    log "ERROR: Installation completed but CLT are still not functional."
    exit 1
fi
