#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${ANSIBLE_DIR:-"$(realpath "$SCRIPT_DIR/..")"}"
DEFAULT_NODE="$(hostname -s)"
NODE_NAME="${1:-$DEFAULT_NODE}"

INVENTORY_FILE="$ANSIBLE_DIR/inventory/hosts.yaml"
PLAYBOOK_FILE="$ANSIBLE_DIR/storage-nodes.yaml"

log() { echo "[gitops-agent:$NODE_NAME] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log "Starting GitOps sync"

START_TS=$(date +%s)
fmt_duration() { printf "%dm%02ds" "$(( ($1)/60 ))" "$(( ($1)%60 ))"; }

LOCK_FILE="${LOCK_FILE:-/run/lock/gitops-agent.lock}"
mkdir -p "$(dirname "$LOCK_FILE")"
exec {lock_fd}>"$LOCK_FILE"
if ! flock -n "$lock_fd"; then
  log "Another run is in progress (lock: $LOCK_FILE). Exiting."
  exit 0
fi

# --- PULL FIRST ---
GIT_ROOT="${GIT_ROOT:-$ANSIBLE_DIR}"
if command -v git >/dev/null 2>&1; then
  if git -C "$GIT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "Updating Git working tree at $GIT_ROOT"
    git -C "$GIT_ROOT" pull --rebase --autostash --prune || \
      log "Warning: git pull failed, continuing with current tree..."
  else
    log "Info: $GIT_ROOT is not a Git work tree; skipping pull"
  fi
else
  log "Info: 'git' not installed; skipping pull"
fi

# Basic path exists (but DO NOT validate inventory/playbook yet)
if [ ! -d "$ANSIBLE_DIR" ]; then
  log "ERROR: ANSIBLE_DIR does not exist: $ANSIBLE_DIR"; exit 1; fi

# --- NOW validate tooling & files ---
need() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: required command '$1' not in PATH"; exit 127; }; }
need ansible-playbook

if [ ! -s "$INVENTORY_FILE" ]; then
  log "ERROR: Inventory file missing or empty: $INVENTORY_FILE"; exit 1; fi
if [ ! -r "$PLAYBOOK_FILE" ]; then
  log "ERROR: Playbook not readable: $PLAYBOOK_FILE"; exit 1; fi

cd "$ANSIBLE_DIR"

log "Running Ansible playbook for $NODE_NAME"
ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK_FILE" --limit "$NODE_NAME"

END_TS=$(date +%s)
DUR=$(( END_TS - START_TS ))
log "Finished GitOps sync in $(fmt_duration "$DUR")"
