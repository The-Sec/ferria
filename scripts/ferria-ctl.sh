#!/usr/bin/env bash
# ferria-ctl.sh — Ferria agent control helper
#
# Provides convenient wrappers around systemctl, journalctl, and ansible-pull
# for common Ferria operations.
#
# Usage: ferria-ctl <command>
# Run 'ferria-ctl help' for the full command list.

set -euo pipefail

CONF_FILE="/etc/ferria/agent.conf"
SERVICE="ferria-agent"
TIMER="${SERVICE}.timer"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  status    Show timer status, last run result, and next scheduled run
  pause     Stop the timer (agent stops reconciling; config remains intact)
  resume    Re-enable and start the timer
  run       Trigger an immediate convergence run (outside timer schedule)
  log       Show recent journal entries for ferria-agent (last 24 hours)
  log-full  Follow the journal in real time (Ctrl+C to stop)
  version   Show installed Ansible, SOPS, age, and repo commit versions
  verify    Dry-run: fetch latest commit and show what would change, without applying

EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "This command must be run as root." >&2
        exit 1
    fi
}

load_config() {
    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    else
        FERRIA_VENV_PATH="/opt/ferria/venv"
        FERRIA_REPO_DEST="/opt/ferria/repo"
        FERRIA_REPO_URL=""
        FERRIA_REPO_BRANCH="main"
        FERRIA_SSH_STRICT_HOST_KEY_CHECKING="accept-new"
    fi
}

cmd_status() {
    echo "=== Ferria Agent Status ==="
    echo

    if ! systemctl list-unit-files "${TIMER}" --no-legend 2>/dev/null | grep -q "${TIMER}"; then
        echo "Ferria timer is not installed on this system."
        echo "Run bootstrap.sh to install Ferria."
        return
    fi

    echo "--- Timer ---"
    systemctl status "${TIMER}" --no-pager 2>/dev/null || true

    echo
    echo "--- Last run (most recent 20 lines) ---"
    journalctl -u "${SERVICE}" --no-pager -n 20 --output short-iso 2>/dev/null \
        || echo "(no log entries found)"
}

cmd_pause() {
    require_root
    echo "Pausing Ferria — stopping and disabling timer..."
    systemctl stop "${TIMER}"
    systemctl disable "${TIMER}"
    echo "Ferria is paused. Agent will not reconcile until resumed."
    echo "Use '$(basename "$0") resume' to re-enable."
}

cmd_resume() {
    require_root
    echo "Resuming Ferria — enabling and starting timer..."
    systemctl enable --now "${TIMER}"
    echo "Ferria is running."
}

cmd_run() {
    require_root
    echo "Triggering immediate convergence run..."
    systemctl start "${SERVICE}.service"
    echo "Run started. Follow with:"
    echo "  $(basename "$0") log-full"
}

cmd_log() {
    journalctl -u "${SERVICE}" --no-pager --since "24 hours ago" --output short-iso
}

cmd_log_full() {
    echo "Following Ferria journal (Ctrl+C to stop)..."
    journalctl -u "${SERVICE}" -f
}

cmd_version() {
    load_config
    echo "=== Ferria Versions ==="

    if [[ -f "${FERRIA_VENV_PATH}/bin/ansible" ]]; then
        echo "Ansible      : $("${FERRIA_VENV_PATH}/bin/ansible" --version | head -1)"
    else
        echo "Ansible      : not found (venv not at ${FERRIA_VENV_PATH})"
    fi

    if command -v sops &>/dev/null; then
        echo "SOPS         : $(sops --version)"
    else
        echo "SOPS         : not installed"
    fi

    if command -v age &>/dev/null; then
        echo "age          : $(age --version)"
    else
        echo "age          : not installed"
    fi

    if [[ -d "${FERRIA_REPO_DEST}/.git" ]]; then
        COMMIT=$(git -C "${FERRIA_REPO_DEST}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        BRANCH=$(git -C "${FERRIA_REPO_DEST}" branch --show-current 2>/dev/null || echo "unknown")
        echo "Repo commit  : ${COMMIT} (${BRANCH})"
        echo "Repo URL     : ${FERRIA_REPO_URL:-unknown}"
    else
        echo "Repo         : not found at ${FERRIA_REPO_DEST}"
    fi
}

cmd_verify() {
    require_root
    load_config

    if [[ -z "${FERRIA_REPO_URL}" ]]; then
        echo "Configuration not found at ${CONF_FILE}" >&2
        echo "Run bootstrap.sh first." >&2
        exit 1
    fi

    echo "Fetching latest state and running dry-run (--check --diff)..."
    echo "Using an isolated temporary checkout to avoid modifying the managed repository."
    echo

    # shellcheck source=/dev/null
    source "${FERRIA_VENV_PATH}/bin/activate"

    if [[ -f "/etc/ferria/age-key.txt" ]]; then
        export SOPS_AGE_KEY_FILE="/etc/ferria/age-key.txt"
    fi

    VERIFY_DIR=$(mktemp -d /tmp/ferria-verify.XXXXXX)
    trap 'rm -rf "$VERIFY_DIR"' RETURN

    GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=${FERRIA_SSH_STRICT_HOST_KEY_CHECKING:-accept-new}" \
    ansible-pull \
        -U "${FERRIA_REPO_URL}" \
        -C "${FERRIA_REPO_BRANCH}" \
        -d "${VERIFY_DIR}" \
        -i inventory/hosts.yml \
        --check \
        --diff \
        local.yml
}

case "${1:-}" in
    status)    cmd_status ;;
    pause)     cmd_pause ;;
    resume)    cmd_resume ;;
    run)       cmd_run ;;
    log)       cmd_log ;;
    log-full)  cmd_log_full ;;
    version)   cmd_version ;;
    verify)    cmd_verify ;;
    ""|-h|--help|help) usage ;;
    *)
        echo "Unknown command: '${1}'" >&2
        echo
        usage
        exit 1
        ;;
esac
