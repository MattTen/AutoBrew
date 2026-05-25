# AutoBrew

Install Homebrew as root for mass deployment on a Mac fleet — compatible with **Intel and Apple Silicon**, Jamf Pro, and direct CLI.

Based on [kennyb-222/AutoBrew](https://github.com/kennyb-222/AutoBrew/), rewritten for modern macOS.

> **Disclaimer:** Running Homebrew as root is not officially supported. This script patches the root check at install time and is intended for managed/MDM environments only.

---

## Usage

**Direct CLI:**
```bash
sudo /bin/bash /path/to/AutoBrew.sh
# or with a specific user:
sudo /bin/bash /path/to/AutoBrew.sh "username"
```

**Jamf Pro:** deploy the script — the target user is read from parameter `$3` (Jamf convention). If omitted, the script detects the currently logged-in console user automatically.

---

## What it does

1. Detects architecture → sets Homebrew prefix (`/opt/homebrew` on Apple Silicon, `/usr/local` on Intel)
2. Validates the target user via `dscl`
3. Downloads and patches Homebrew's install script (bypasses root check, disables interactive prompts via `NONINTERACTIVE=1`)
4. Fixes ownership so the target user — not root — owns the Homebrew install
5. Runs `brew update`, `brew cleanup`, and `brew doctor` as the target user; auto-applies any remediation commands suggested by `doctor`

---

## Requirements

- macOS (Intel or Apple Silicon)
- Must be run as root (`sudo`)
- Target user must exist and be a valid local account
