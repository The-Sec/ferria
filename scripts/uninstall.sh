#!/usr/bin/env bash
# uninstall.sh — Remove Ferria from a machine
#
# Stops and disables the timer, removes systemd unit files.
# Optionally removes /opt/ferria/ (repo + venv) and /etc/ferria/ (config + keys).
#
# Does NOT undo changes made by Ferria's playbooks (installed packages,
# configuration files, etc.) — those are the operator's responsibility.
#
# Usage: uninstall.sh [-y] [-a] [-h]
#   -y  Skip confirmation prompts (non-interactive mode)
#   -a  Also remove /opt/ferria/ and /etc/ferria/
#   -h  Show this help

set -euo pipefail

SKIP_CONFIRM=false
REMOVE_ALL=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [-y] [-a] [-h]

Options:
  -y  Skip confirmation prompts (non-interactive mode)
  -a  Also remove /opt/ferria/ (repo + venv) and /etc/ferria/ (config + keys)
  -h  Show this help

Note: This script does NOT undo changes applied by Ferria's playbooks.
      Packages installed and files written by roles remain intact.
EOF
}

confirm() {
    local prompt="$1"
    if [[ "$SKIP_CONFIRM" == "true" ]]; then
        return 0
    fi
    read -r -p "${prompt} [y/N] " response
    [[ "${response}" =~ ^[Yy]$ ]]
}

while getopts "yah" opt; do
    case "$opt" in
        y) SKIP_CONFIRM=true ;;
        a) REMOVE_ALL=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

echo "=== Ferria Uninstall ==="
echo
echo "This will:"
echo "  - Stop and disable ferria-agent.timer and ferria-agent.service"
echo "  - Remove /etc/systemd/system/ferria-agent.service"
echo "  - Remove /etc/systemd/system/ferria-agent.timer"
if [[ "$REMOVE_ALL" == "true" ]]; then
    echo "  - Remove /opt/ferria/ (Ansible venv + repo clone)"
    echo "  - Remove /etc/ferria/ (agent config + age private key)"
fi
echo
echo "This does NOT undo changes applied by Ferria's playbooks."
echo

if ! confirm "Continue with uninstall?"; then
    echo "Uninstall cancelled."
    exit 0
fi

# --- Step 1: Stop and disable timer and service ---
echo "Stopping ferria-agent.timer and ferria-agent.service..."
systemctl stop ferria-agent.timer  2>/dev/null || true
systemctl stop ferria-agent.service 2>/dev/null || true

echo "Disabling ferria-agent.timer..."
systemctl disable ferria-agent.timer 2>/dev/null || true

# --- Step 2: Remove unit files ---
echo "Removing systemd unit files..."
rm -f /etc/systemd/system/ferria-agent.service
rm -f /etc/systemd/system/ferria-agent.timer

# --- Step 3: Reload systemd ---
echo "Reloading systemd daemon..."
systemctl daemon-reload

# --- Step 4: Optionally remove data directories ---
if [[ "$REMOVE_ALL" == "true" ]]; then
    if [[ -d /opt/ferria ]] && confirm "Remove /opt/ferria/ (repo + venv)?"; then
        rm -rf /opt/ferria/
        echo "Removed /opt/ferria/"
    fi

    if [[ -d /etc/ferria ]]; then
        echo
        echo "WARNING: /etc/ferria/ contains your age private key."
        echo "         Secrets encrypted for this machine will no longer be decryptable."
        if confirm "Remove /etc/ferria/ (config + age key)?"; then
            rm -rf /etc/ferria/
            echo "Removed /etc/ferria/"
        fi
    fi
fi

echo
echo "Ferria has been uninstalled."
echo
echo "Note: Packages and configuration files applied by Ferria's playbooks remain."
echo "      Manage them manually or with another tool."
