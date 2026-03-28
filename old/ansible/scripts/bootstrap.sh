#!/bin/bash
set -euo pipefail

# Fixed cluster name
CLUSTER_NAME="swh41"

GIT_REPO_SSH="git@github.com:The-Sec/gitops-lab.git"
CLONE_DIR="/opt/gitops-lab"
SSH_KEY_PATH="/root/.ssh/gitops"
KNOWN_HOSTS_PATH="/root/.ssh/known_hosts"
SSH_CONFIG_PATH="/root/.ssh/config"

log() {
  echo "[bootstrap] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Step 1: Install only essential packages for running ansible
log "Installing minimal packages (git, ansible)..."
apt update
apt install -y --no-install-recommends git ansible

# Step 2: Generate SSH key if it doesn't exist
if [ ! -f "$SSH_KEY_PATH" ]; then
  log "Generating new SSH key for this host..."
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N ""
  chmod 600 "$SSH_KEY_PATH"
  log "Public key generated (copy this to GitHub as a deploy key):"
  echo "----------------------------------------"
  cat "${SSH_KEY_PATH}.pub" | tee "/root/gitops-deploy-key.pub"
  echo "----------------------------------------"
  echo
  log "NOTE: Please add this public key as a read-only deploy key in your repository settings."
  log "Sleeping for 30 seconds to give you a chance to add the key..."
  sleep 30
else
  log "SSH key already exists, skipping generation."
fi

# Step 3: Create or update SSH config for GitHub (idempotent)
log "Ensuring SSH config for GitHub uses correct key..."
mkdir -p "$(dirname "$SSH_CONFIG_PATH")"
if ! grep -q "Host github.com" "$SSH_CONFIG_PATH" 2>/dev/null; then
  cat <<EOF >> "$SSH_CONFIG_PATH"
Host github.com
  IdentityFile $SSH_KEY_PATH
  IdentitiesOnly yes
EOF
  chmod 600 "$SSH_CONFIG_PATH"
fi

# Step 4: Ensure GitHub is in known_hosts (idempotent)
log "Ensuring github.com is in known_hosts..."
mkdir -p "$(dirname "$KNOWN_HOSTS_PATH")"
if ! grep -q "github.com" "$KNOWN_HOSTS_PATH" 2>/dev/null; then
  ssh-keyscan github.com >> "$KNOWN_HOSTS_PATH"
  chmod 600 "$KNOWN_HOSTS_PATH"
fi

# Step 5: Clone the Git repository (idempotent)
if [ ! -d "$CLONE_DIR/.git" ]; then
  log "Cloning Git repository..."
  GIT_SSH_COMMAND="ssh -i $SSH_KEY_PATH -o IdentitiesOnly=yes" git clone "$GIT_REPO_SSH" "$CLONE_DIR"
else
  log "Git repository already present at $CLONE_DIR, pulling latest changes..."
  cd "$CLONE_DIR"
  GIT_SSH_COMMAND="ssh -i $SSH_KEY_PATH -o IdentitiesOnly=yes" git pull --rebase || log "Warning: git pull failed, continuing with local copy."
fi

# Step 6: Run Ansible playbook (install-puller.sh)
ANSIBLE_SCRIPTS_PATH="$CLONE_DIR/clusters/swh41/bootstrap/ansible/scripts"
INSTALL_PULLER_SCRIPT="$ANSIBLE_SCRIPTS_PATH/sync-and-apply.sh"

if [ -x "$INSTALL_PULLER_SCRIPT" ]; then
  log "Running cluster install-puller script to finish bootstrap..."
  bash "$INSTALL_PULLER_SCRIPT"
else
  log "ERROR: install-puller.sh not found or not executable at $INSTALL_PULLER_SCRIPT"
  exit 2
fi

log "Bootstrap complete!"
