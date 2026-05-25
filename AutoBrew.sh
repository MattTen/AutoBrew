#!/bin/bash
# AutoBrew - Install Homebrew as root (Intel + Apple Silicon)
# Based on: https://github.com/kennyb-222/AutoBrew/
# Updated: 2026

# Detect architecture and set Homebrew prefix accordingly
ARCH=$(uname -m)
if [ "${ARCH}" = "arm64" ]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi
BREW_BIN="${BREW_PREFIX}/bin/brew"

# Temporary HOME so root doesn't pollute a real user's home
HOME="$(mktemp -d)"
BREW_INSTALL_LOG=$(mktemp)
AUTOBREW_LOG="/var/log/autobrew.log"
export HOME
trap "rm -rf '${HOME}'; rm -f '${BREW_INSTALL_LOG}'" EXIT

# log() writes to stdout (captured by NinjaOne) AND to the persistent log file
log() { echo "$@"; echo "$@" >> "${AUTOBREW_LOG}"; }
log "=== AutoBrew started at $(date) ==="
export USER=root
export PATH="${BREW_PREFIX}/sbin:${BREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Detect current console user as default (overridden by --username if given)
TargetUser=$(echo "show State:/Users/ConsoleUser" | \
    scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }')
Password=""

# Parse --username / --password flags.
# Prepend $0 to handle both invocation styles:
#   bash AutoBrew.sh --username u --password p   → $1=--username
#   /bin/bash -c "$(curl ...)" --username u ...  → $0=--username
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

# Run a command with a timeout (seconds). macOS has no GNU timeout — use background job.
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

# Pre-install Xcode Command Line Tools if missing (Homebrew requires them)
# Check if developer tools are available — xcode-select, CLT dir, Xcode.app, or xcrun
_devtools_ok() {
    /usr/bin/xcode-select -p >/dev/null 2>&1 && return 0
    [ -d "/Library/Developer/CommandLineTools/usr/bin" ] && return 0
    [ -d "/Applications/Xcode.app/Contents/Developer" ] && return 0
    xcrun --find git >/dev/null 2>&1 && return 0
    return 1
}

if ! _devtools_ok; then
    if [ -d "/Library/Developer/CommandLineTools" ]; then
        # Directory exists but xcode-select path is broken — just fix the pointer
        log "Fixing Xcode Command Line Tools path..."
        /usr/bin/xcode-select --switch /Library/Developer/CommandLineTools
    elif [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        # Full Xcode.app is installed — use it as the developer directory
        log "Using Xcode.app as developer tools..."
        /usr/bin/xcode-select -s /Applications/Xcode.app
    else
        log "Installing Xcode Command Line Tools..."
        touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

        _clt_grep() { grep -E 'Command Line Tools' | sed 's/.*Label: //;s/.*\* //' | grep -v '^ *$' | sort -V | tail -1; }

        # 1. Default catalog as root (60s timeout)
        CLT_PKG=$(_with_timeout 60 softwareupdate -l 2>/dev/null | _clt_grep)

        # 2. --all: includes non-recommended packages (needed on new Macs / macOS 14+)
        if [ -z "${CLT_PKG}" ]; then
            CLT_PKG=$(_with_timeout 60 softwareupdate -l --all 2>/dev/null | _clt_grep)
        fi

        # 3. As console user: modern macOS restricts catalog visibility differently for root
        if [ -z "${CLT_PKG}" ]; then
            CLT_PKG=$(_with_timeout 60 sudo -n -u "${TargetUser}" -H softwareupdate -l 2>/dev/null | _clt_grep)
        fi

        rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

        if [ -z "${CLT_PKG}" ]; then
            MACOS_VER=$(sw_vers -productVersion)
            log "WARNING: Command Line Tools not found via softwareupdate on macOS ${MACOS_VER}."
            if [ -n "${Password}" ]; then
                # With credentials: osascript authenticates the request in the user's GUI session
                log "Triggering CLT install via osascript (a dialog will appear on screen)..."
                osascript -e "do shell script \"/usr/bin/xcode-select --install\" user name \"${TargetUser}\" password \"${Password}\" with administrator privileges" 2>/dev/null || true
            else
                # Without credentials: launchctl reaches the user's window server session
                log "Triggering CLT install via launchctl (a dialog will appear on screen)..."
                _tuid=$(id -u "${TargetUser}" 2>/dev/null)
                [ -n "${_tuid}" ] && launchctl asuser "${_tuid}" /usr/bin/xcode-select --install 2>/dev/null || true
            fi
            log "Waiting up to 5 minutes for CLT installation..."
            _clt_waited=0
            while [ "${_clt_waited}" -lt 300 ]; do
                sleep 20
                _clt_waited=$((_clt_waited + 20))
                if _devtools_ok; then
                    log "CLT installed successfully."
                    break
                fi
            done
            if ! _devtools_ok; then
                log "CLT installation timed out — proceeding anyway (Homebrew may fail)."
                log "If it fails, install Xcode from: https://developer.apple.com/xcode/"
            fi
        fi

        if [ -n "${CLT_PKG}" ]; then
            log "Installing CLT package: ${CLT_PKG}"
            softwareupdate -i "${CLT_PKG}" --agree-to-license
            if ! _devtools_ok; then
                log "Xcode Command Line Tools installation failed"
                exit 1
            fi
        fi
    fi
fi

# Install Homebrew:
#   - NONINTERACTIVE=1 skips all interactive prompts (official Homebrew support)
#   - 1st sed: patches out the root check in install.sh (bash-level)
#   - 2nd sed: skips the internal "brew update --force --quiet" that install.sh runs
#     as root at the end — brew's Ruby binary has its own root check that blocks it.
#     We already run "brew update --force" as the target user right after.
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | \
    sed "s/abort \"Don't run this as root\!\"/echo \"WARNING: Running as root...\"/" | \
    sed 's|.*"update".*"--force".*"--quiet".*|  echo "Skipping internal brew update (will run as target user)"|' | \
    sed 's/should_install_command_line_tools && test -t 0/false/')" \
    2>&1 | tee "${BREW_INSTALL_LOG}"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log "Homebrew installer failed"
    exit 1
fi

# Fix ownership so the target user (not root) owns the Homebrew install
if [ "${ARCH}" = "arm64" ]; then
    # Apple Silicon: Homebrew owns /opt/homebrew entirely — safe to chown the whole prefix
    chown -R "${TargetUser}":admin "${BREW_PREFIX}"
else
    # Intel: /usr/local is a shared system directory — only chown what Homebrew touched
    # Strip ANSI escape codes in case the log captured color output
    clean_log=$(perl -pe 's/\e\[[0-9;]*m//g' "${BREW_INSTALL_LOG}")
    brew_file_paths=$(echo "${clean_log}" | sed '1,/==> This script will install:/d;/==> /,$d')
    brew_dir_paths=$(echo "${clean_log}" | sed '1,/==> The following new directories will be created:/d;/==> /,$d')
    brew_bin_path="${BREW_BIN%/brew}"

    if [ -n "${brew_file_paths}" ]; then
        # shellcheck disable=SC2086
        chown -R "${TargetUser}":admin ${brew_file_paths}
    fi
    if [ -n "${brew_dir_paths}" ]; then
        # shellcheck disable=SC2086
        chown -R "${TargetUser}":admin ${brew_dir_paths}
    fi
    chgrp admin "${brew_bin_path}/"
    chmod g+w "${brew_bin_path}"
fi

unset HOME
unset USER
unset Password

# Finalize the install as the target user
sudo -n -u "${TargetUser}" -H "${BREW_BIN}" update --force || { log "brew update failed"; exit 1; }
sudo -n -u "${TargetUser}" -H "${BREW_BIN}" cleanup

# Run brew doctor and auto-apply any remediation commands it suggests
doctor_cmds=$(sudo -n -u "${TargetUser}" -H "${BREW_BIN}" doctor 2>&1 | grep -E 'mkdir|chown|chmod|echo|&&')

if [ -n "${doctor_cmds}" ]; then
    log "\"brew doctor\" failed. Attempting to repair..."
    while IFS= read -r line; do
        log "RUNNING: ${line}"
        if [[ "${line}" == *sudo* ]]; then
            cmd_modified=$(echo "${line}" | sed "s/sudo //g; s/\$(whoami)/${TargetUser}/g")
            bash -c "${cmd_modified}"
        else
            sudo -n -u "${TargetUser}" -H bash -c "${line}"
        fi
    done <<< "${doctor_cmds}"
fi

if sudo -n -u "${TargetUser}" -H "${BREW_BIN}" doctor; then
    log "Homebrew installation complete! Your system is ready to brew."
    log "=== AutoBrew finished successfully at $(date) ==="
    exit 0
else
    log "AutoBrew installation failed."
    log "=== AutoBrew failed at $(date) — see above for details ==="
    exit 1
fi