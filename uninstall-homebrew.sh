#!/bin/bash
# AutoBrew Uninstaller - Deep removal of Homebrew (Intel + Apple Silicon)
# Companion to AutoBrew.sh — compatible with MDM/Jamf deployments
# Updated: 2026

ARCH=$(uname -m)
if [ "${ARCH}" = "arm64" ]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi
BREW_BIN="${BREW_PREFIX}/bin/brew"

HOME="$(mktemp -d)"
AUTOBREW_LOG="/var/log/autobrew.log"
export HOME
trap "rm -rf '${HOME}'" EXIT

log() { echo "$@"; echo "$@" >> "${AUTOBREW_LOG}"; }
log "=== AutoBrew Uninstaller started at $(date) ==="
export USER=root
export PATH="${BREW_PREFIX}/sbin:${BREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Detect current console user (overridden by --username/-u)
TargetUser=$(echo "show State:/Users/ConsoleUser" | \
    scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }')
Password=""

# Parse --username / --password flags.
# Prepend $0 to handle both invocation styles:
#   bash uninstall-homebrew.sh --username u   → $1=--username
#   /bin/bash -c "$(curl ...)" --username u   → $0=--username
_args=("$0" "$@")
_i=0
while [ "${_i}" -lt "${#_args[@]}" ]; do
    case "${_args[${_i}]}" in
        --username|-u) _i=$((_i + 1)); [ "${_i}" -lt "${#_args[@]}" ] && TargetUser="${_args[${_i}]}" ;;
        --password|-p) _i=$((_i + 1)); [ "${_i}" -lt "${#_args[@]}" ] && Password="${_args[${_i}]}" ;;
    esac
    _i=$((_i + 1))
done
unset _i _args

# Legacy positional fallback: Jamf $3 or direct CLI $1 (only if --username was not given)
if [ -z "${TargetUser}" ]; then
    if [ -n "$3" ] && [[ "$3" != -* ]]; then
        TargetUser="$3"
    elif [ -n "$1" ] && [[ "$1" != -* ]]; then
        TargetUser="$1"
    fi
fi

if [ -z "${TargetUser}" ]; then
    log "'TargetUser' is empty. You must specify a user!"
    exit 1
fi

if /usr/bin/dscl . -read "/Users/${TargetUser}" >/dev/null 2>&1; then
    log "Validated ${TargetUser}"
else
    log "Specified user \"${TargetUser}\" is invalid"
    exit 1
fi

USER_HOME=$(dscl . -read "/Users/${TargetUser}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -z "${USER_HOME}" ] && USER_HOME="/Users/${TargetUser}"

# Early exit if Homebrew is not present
if [ ! -f "${BREW_BIN}" ] && [ ! -d "${BREW_PREFIX}/Homebrew" ] && [ ! -d "/opt/homebrew" ]; then
    log "Homebrew does not appear to be installed at ${BREW_PREFIX}. Nothing to remove."
    exit 0
fi

log "Target user : ${TargetUser}"
log "User home   : ${USER_HOME}"
log "Brew prefix : ${BREW_PREFIX}"

# ─── Step 1: Shell profile dotfiles ──────────────────────────────────────────
# Done first so tools installed via Homebrew (python3, etc.) are still available.
log "--- Step 1: Cleaning shell profile dotfiles ---"

_clean_profile() {
    local file="$1"
    [ -f "${file}" ] || return
    local bak="${file}.brew-uninstall.bak"
    local tmp
    tmp=$(mktemp)
    cp "${file}" "${bak}"
    # Single-pass awk: removes Homebrew lines and the Homebrew comment that precedes them.
    awk '
        BEGIN { prev=""; is_brew_comment=0 }
        /eval.*brew[[:space:]]*shellenv|HOMEBREW_(PREFIX|CELLAR|REPOSITORY|SHELLENV)|\/opt\/homebrew|homebrew\/(bin|sbin)/ {
            if (is_brew_comment) prev=""
            is_brew_comment=0
            next
        }
        {
            if (prev!="") print prev
            prev=$0
            is_brew_comment = (/^[[:space:]]*#/ && /[Hh]omebrew|brew shellenv/)
        }
        END { if (prev!="") print prev }
    ' "${file}" > "${tmp}"
    if ! diff -q "${file}" "${tmp}" >/dev/null 2>&1; then
        cat "${tmp}" > "${file}"
        log "Cleaned ${file} (backup: ${bak})"
    else
        rm -f "${bak}"
        log "No Homebrew entries in ${file}"
    fi
    rm -f "${tmp}"
}

for _profile in \
    "${USER_HOME}/.zshrc" "${USER_HOME}/.zprofile" \
    "${USER_HOME}/.bash_profile" "${USER_HOME}/.bashrc" "${USER_HOME}/.profile" \
    /etc/zshrc /etc/zprofile; do
    _clean_profile "${_profile}"
done
unset _profile

# ─── Step 2: Official Homebrew uninstall script ──────────────────────────────
log "--- Step 2: Running Homebrew official uninstall script ---"
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" \
    2>&1 | while IFS= read -r line; do log "${line}"; done
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log "WARNING: Official uninstaller exited non-zero — continuing manual cleanup"
fi

# ─── Step 3: Prefix remnants ─────────────────────────────────────────────────
log "--- Step 3: Removing Homebrew prefix remnants ---"
if [ "${ARCH}" = "arm64" ]; then
    # Apple Silicon: /opt/homebrew belongs entirely to Homebrew
    if [ -d "/opt/homebrew" ]; then
        rm -rf /opt/homebrew && log "Removed /opt/homebrew"
    fi
else
    # Intel: /usr/local is shared — only remove Homebrew-owned subdirectories
    for _dir in Cellar Caskroom Frameworks Homebrew; do
        [ -d "/usr/local/${_dir}" ] && rm -rf "/usr/local/${_dir}" && log "Removed /usr/local/${_dir}"
    done
    [ -f "/usr/local/bin/brew" ] && rm -f "/usr/local/bin/brew" && log "Removed /usr/local/bin/brew"
    [ -d "/usr/local/var/homebrew" ] && rm -rf "/usr/local/var/homebrew" && log "Removed /usr/local/var/homebrew"
    # Remove dirs only if empty (may contain non-Homebrew files on Intel)
    for _dir in opt share include lib etc; do
        [ -d "/usr/local/${_dir}" ] && rmdir "/usr/local/${_dir}" 2>/dev/null \
            && log "Removed empty /usr/local/${_dir}"
    done
    unset _dir
fi

# ─── Step 4: User-level caches and data ──────────────────────────────────────
log "--- Step 4: Removing user-level Homebrew files ---"
for _path in \
    "${USER_HOME}/Library/Caches/Homebrew" \
    "${USER_HOME}/Library/Logs/Homebrew" \
    "${USER_HOME}/Library/Application Support/Homebrew" \
    "${USER_HOME}/.homebrew" \
    "${USER_HOME}/.config/brew"; do
    if [ -e "${_path}" ]; then
        rm -rf "${_path}" && log "Removed ${_path}"
    fi
done
unset _path

# ─── Step 5: System PATH entries ─────────────────────────────────────────────
log "--- Step 5: Removing system PATH entries ---"
[ -f "/etc/paths.d/homebrew" ] && rm -f "/etc/paths.d/homebrew" && log "Removed /etc/paths.d/homebrew"

# ─── Step 6: LaunchAgents / LaunchDaemons ────────────────────────────────────
log "--- Step 6: Removing Homebrew launchd services ---"
TUID=$(id -u "${TargetUser}" 2>/dev/null)

for _plist in "${USER_HOME}/Library/LaunchAgents/homebrew."*.plist; do
    [ -f "${_plist}" ] || continue
    [ -n "${TUID}" ] && launchctl asuser "${TUID}" launchctl unload "${_plist}" 2>/dev/null || true
    rm -f "${_plist}" && log "Removed LaunchAgent: ${_plist}"
done
for _plist in /Library/LaunchDaemons/homebrew.*.plist; do
    [ -f "${_plist}" ] || continue
    launchctl unload "${_plist}" 2>/dev/null || true
    rm -f "${_plist}" && log "Removed LaunchDaemon: ${_plist}"
done
unset _plist

# ─── Step 7: Temp and lock files ─────────────────────────────────────────────
log "--- Step 7: Removing Homebrew temp/lock files ---"
while IFS= read -r -d '' _f; do
    rm -rf "${_f}" && log "Removed ${_f}"
done < <(find /tmp -maxdepth 1 \( -name 'homebrew-*' -o -name 'brew-*' \) -print0 2>/dev/null)
unset _f

unset HOME
unset USER
unset Password

# ─── Verification ─────────────────────────────────────────────────────────────
log "--- Verification ---"
_remaining=0
[ -f "${BREW_BIN}" ]         && log "WARNING: ${BREW_BIN} still present"          && _remaining=1
[ -d "/opt/homebrew" ]       && log "WARNING: /opt/homebrew still present"         && _remaining=1
[ -d "/usr/local/Homebrew" ] && log "WARNING: /usr/local/Homebrew still present"   && _remaining=1
[ -d "/usr/local/Cellar" ]   && log "WARNING: /usr/local/Cellar still present"     && _remaining=1

if [ "${_remaining}" -eq 0 ]; then
    log "Homebrew has been successfully removed from this system."
    log "=== AutoBrew Uninstaller finished successfully at $(date) ==="
    exit 0
else
    log "Some Homebrew files may still remain — manual inspection recommended."
    log "=== AutoBrew Uninstaller finished with warnings at $(date) ==="
    exit 1
fi
