#!/usr/bin/env bash
# bootstrap.sh — Ferria one-shot bootstrap script
#
# Provisions a fresh machine to be managed by the Ferria GitOps agent.
# Idempotent: safe to run multiple times.
#
# Usage: bootstrap.sh -r <git-repo-url> [-b <branch>] [-i <interval>] [-j] [-v] [-h]
#   -r  Git repository URL (SSH format, e.g., git@github.com:user/infra.git)  [required]
#   -b  Git branch to track (default: main)
#   -i  Pull interval in minutes (default: 30)
#   -j  Enable thundering herd jitter
#   -v  Enable commit signature verification (requires signed commits)
#   -k  SSH StrictHostKeyChecking policy: yes|accept-new|no (default: accept-new)
#   -h  Show this help message

set -euo pipefail

# --- Constants ---
FERRIA_VENV="/opt/ferria/venv"
FERRIA_REPO_DEST="/opt/ferria/repo"
FERRIA_CONF_DIR="/etc/ferria"
FERRIA_CONF_FILE="${FERRIA_CONF_DIR}/agent.conf"
FERRIA_SSH_KEY="/root/.ssh/id_ed25519"

# --- Defaults ---
REPO_URL=""
BRANCH="main"
INTERVAL=30
JITTER_ENABLED="false"
JITTER_MAX_SEC=300
COMMIT_VERIFY="false"
SSH_STRICT_HOST_KEY_CHECKING="accept-new"

# --- Cleanup trap ---
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Bootstrap failed with exit code ${exit_code}."
        log_error "Check the output above for details."
    fi
}
trap cleanup EXIT

# --- Logging ---
log()       { echo "[ferria] $*"; }
log_error() { echo "[ferria] ERROR: $*" >&2; }
log_warn()  { echo "[ferria] WARN:  $*" >&2; }

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") -r <git-repo-url> [-b <branch>] [-i <interval>] [-j] [-v] [-k <policy>] [-h]

Options:
  -r  Git repository URL (SSH format, e.g., git@github.com:user/infra.git)  [required]
  -b  Git branch to track (default: main)
  -i  Pull interval in minutes (default: 30)
  -j  Enable thundering herd jitter (random delay before each pull)
  -v  Enable commit signature verification (requires GPG or SSH-signed commits)
    -k  SSH StrictHostKeyChecking policy: yes|accept-new|no (default: accept-new)
  -h  Show this help message

Example:
  $(basename "$0") -r git@github.com:myorg/infra.git -b main -i 30 -j
EOF
}

# --- Argument parsing ---
while getopts "r:b:i:jvk:h" opt; do
    case "$opt" in
        r) REPO_URL="$OPTARG" ;;
        b) BRANCH="$OPTARG" ;;
        i) INTERVAL="$OPTARG" ;;
        j) JITTER_ENABLED="true" ;;
        v) COMMIT_VERIFY="true" ;;
        k) SSH_STRICT_HOST_KEY_CHECKING="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

if [[ -z "$REPO_URL" ]]; then
    log_error "Git repository URL is required (-r)"
    usage
    exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

if [[ "$SSH_STRICT_HOST_KEY_CHECKING" != "yes" && "$SSH_STRICT_HOST_KEY_CHECKING" != "accept-new" && "$SSH_STRICT_HOST_KEY_CHECKING" != "no" ]]; then
    log_error "Invalid -k value: ${SSH_STRICT_HOST_KEY_CHECKING}. Expected yes, accept-new, or no."
    exit 1
fi

# ============================================================
# Step 1: Detect OS and package manager
# ============================================================
detect_os() {
    log "Step 1/10: Detecting OS and package manager..."

    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS: /etc/os-release not found."
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-unknown}"

    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -qq"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf check-update -q; true"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum check-update -q; true"
    else
        log_error "Unsupported distribution: '${OS_ID}'."
        log_error "Supported: Debian/Ubuntu (apt), RHEL/Rocky/AlmaLinux (dnf/yum)."
        exit 1
    fi

    log "  OS: ${OS_ID} | Package manager: ${PKG_MANAGER}"
}

# ============================================================
# Step 2: Install system dependencies
# ============================================================
install_system_deps() {
    log "Step 2/10: Installing system dependencies..."
    eval "$PKG_UPDATE"

    if [[ "$PKG_MANAGER" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive $PKG_INSTALL \
            git \
            python3 \
            python3-pip \
            python3-venv \
            openssh-client \
            curl \
            wget \
            gnupg2
    else
        $PKG_INSTALL \
            git \
            python3 \
            python3-pip \
            openssh-clients \
            curl \
            wget \
            gnupg2
    fi

    log "  System dependencies installed."
}

# ============================================================
# Step 3: Install Ansible in a Python venv
# ============================================================
install_ansible() {
    log "Step 3/10: Setting up Python venv at ${FERRIA_VENV}..."
    mkdir -p "$(dirname "$FERRIA_VENV")"

    if [[ ! -d "$FERRIA_VENV" ]]; then
        python3 -m venv "$FERRIA_VENV"
        log "  Python venv created."
    else
        log "  Python venv already exists, skipping creation."
    fi

    log "  Installing/upgrading Ansible in venv (pinned versions)..."
    "${FERRIA_VENV}/bin/pip" install --quiet --upgrade pip
    "${FERRIA_VENV}/bin/pip" install --quiet \
        'ansible-core>=2.16,<2.18' \
        'ansible>=9.0,<11.0' \
        'jinja2>=3.1' \
        'pyyaml>=6.0'

    ANSIBLE_VERSION=$("${FERRIA_VENV}/bin/ansible" --version | head -1)
    log "  Ansible installed: ${ANSIBLE_VERSION}"
}

# ============================================================
# Step 4: Install SOPS and age
# ============================================================
install_age_from_github() {
    log "  Downloading age from GitHub releases..."
    AGE_VERSION=$(curl -fsSL "https://api.github.com/repos/FiloSottile/age/releases/latest" \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    AGE_ARCH="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && AGE_ARCH="arm64"

    TMPDIR=$(mktemp -d)
    curl -fsSL \
        "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${AGE_ARCH}.tar.gz" \
        | tar -xz -C "$TMPDIR"
    install -m 755 "$TMPDIR/age/age" /usr/local/bin/age
    install -m 755 "$TMPDIR/age/age-keygen" /usr/local/bin/age-keygen
    rm -rf "$TMPDIR"
}

install_sops_age() {
    log "Step 4/10: Installing SOPS and age..."

    # SOPS
    if command -v sops &>/dev/null; then
        log "  SOPS already installed: $(sops --version)"
    else
        log "  Downloading SOPS from GitHub releases..."
        SOPS_VERSION=$(curl -fsSL "https://api.github.com/repos/getsops/sops/releases/latest" \
            | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
        SOPS_ARCH="amd64"
        [[ "$(uname -m)" == "aarch64" ]] && SOPS_ARCH="arm64"

        curl -fsSL \
            "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${SOPS_ARCH}" \
            -o /usr/local/bin/sops
        chmod +x /usr/local/bin/sops
        log "  SOPS installed: $(sops --version)"
    fi

    # age
    if command -v age &>/dev/null; then
        log "  age already installed: $(age --version)"
    else
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y age 2>/dev/null \
                && log "  age installed via apt." \
                || { log_warn "age not in apt repositories."; install_age_from_github; }
        elif [[ "$PKG_MANAGER" == "dnf" ]]; then
            dnf install -y age 2>/dev/null \
                && log "  age installed via dnf." \
                || { log_warn "age not in dnf repositories."; install_age_from_github; }
        else
            install_age_from_github
        fi
        log "  age installed: $(age --version)"
    fi
}

# ============================================================
# Step 5: Validate SSH key
# ============================================================
validate_ssh_key() {
    log "Step 5/10: Validating SSH deploy key..."

    if [[ ! -f "$FERRIA_SSH_KEY" ]]; then
        log_error "SSH key not found at ${FERRIA_SSH_KEY}."
        cat >&2 <<EOF

To create a deploy key and authorise this machine:

  1. Generate an SSH key pair:
       ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "ferria@$(hostname -s)"

  2. Display the public key:
       cat /root/.ssh/id_ed25519.pub

  3. Add it as a read-only deploy key in your Git repository settings:
       GitHub: Settings → Deploy keys → Add deploy key

  4. Re-run this bootstrap script.

EOF
        exit 1
    fi

    log "  SSH key found at ${FERRIA_SSH_KEY}."
}

# ============================================================
# Step 6: Clone or update the repository
# ============================================================
clone_or_update_repo() {
    log "Step 6/10: Setting up repository at ${FERRIA_REPO_DEST}..."
    mkdir -p "$(dirname "$FERRIA_REPO_DEST")"

    if [[ -d "${FERRIA_REPO_DEST}/.git" ]]; then
        log "  Repository already cloned — fetching latest..."
        GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}" \
            git -C "$FERRIA_REPO_DEST" fetch origin
        git -C "$FERRIA_REPO_DEST" checkout "$BRANCH"
        git -C "$FERRIA_REPO_DEST" reset --hard "origin/${BRANCH}"
        COMMIT=$(git -C "$FERRIA_REPO_DEST" rev-parse --short HEAD)
        log "  Repository updated to ${COMMIT} on ${BRANCH}."
    else
        log "  Cloning ${REPO_URL} (branch: ${BRANCH})..."
        GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}" \
            git clone --branch "$BRANCH" "$REPO_URL" "$FERRIA_REPO_DEST"
        COMMIT=$(git -C "$FERRIA_REPO_DEST" rev-parse --short HEAD)
        log "  Repository cloned at ${COMMIT}."
    fi
}

# ============================================================
# Step 7: Run initial ansible-pull
# ============================================================
run_initial_pull() {
    log "Step 7/10: Running initial ansible-pull..."

    export SOPS_AGE_KEY_FILE="${FERRIA_CONF_DIR}/age-key.txt"
    export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}"

    "${FERRIA_VENV}/bin/ansible-pull" \
        -U "$REPO_URL" \
        -C "$BRANCH" \
        -d "$FERRIA_REPO_DEST" \
        -i inventory/hosts.yml \
        local.yml

    log "  Initial ansible-pull complete."
}

# ============================================================
# Step 8: Write configuration file
# ============================================================
write_config() {
    log "Step 8/10: Writing configuration to ${FERRIA_CONF_FILE}..."
    mkdir -p "$FERRIA_CONF_DIR"

    cat > "$FERRIA_CONF_FILE" <<EOF
# Ferria agent configuration
# Written by bootstrap.sh on $(date -Iseconds)
# Also managed by the ferria_agent Ansible role — manual edits will be overwritten.
FERRIA_REPO_URL="${REPO_URL}"
FERRIA_REPO_BRANCH="${BRANCH}"
FERRIA_REPO_DEST="${FERRIA_REPO_DEST}"
FERRIA_PULL_INTERVAL="${INTERVAL}"
FERRIA_JITTER_ENABLED="${JITTER_ENABLED}"
FERRIA_JITTER_MAX_SEC="${JITTER_MAX_SEC}"
FERRIA_COMMIT_VERIFY="${COMMIT_VERIFY}"
FERRIA_VENV_PATH="${FERRIA_VENV}"
FERRIA_AGE_KEY_PATH="${FERRIA_CONF_DIR}/age-key.txt"
FERRIA_SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING}"
FERRIA_ONLY_IF_CHANGED="true"
FERRIA_CLEAN_CHECKOUT="true"
EOF
    chmod 600 "$FERRIA_CONF_FILE"
    log "  Configuration written."
}

# ============================================================
# Step 9: Enable and start the timer
# ============================================================
enable_timer() {
    log "Step 9/10: Enabling Ferria systemd timer..."
    systemctl daemon-reload
    systemctl enable --now ferria-agent.timer
    log "  Timer enabled and started."
}

# ============================================================
# Step 10: Print success message
# ============================================================
print_success() {
    log "Step 10/10: Bootstrap complete."
    cat <<EOF

=============================================================
  Ferria bootstrap complete!
=============================================================

  Repository : ${REPO_URL}
  Branch     : ${BRANCH}
  Interval   : every ${INTERVAL} minutes
  Config     : ${FERRIA_CONF_FILE}

Useful commands:

  Check timer status  :  systemctl status ferria-agent.timer
  View recent logs    :  journalctl -u ferria-agent --since "1 hour ago"
  Follow logs live    :  journalctl -u ferria-agent -f
  Trigger run now     :  systemctl start ferria-agent.service
  Control helper      :  ${FERRIA_REPO_DEST}/scripts/ferria-ctl.sh status

=============================================================
EOF
}

# ============================================================
# Main
# ============================================================
main() {
    log "Starting Ferria bootstrap..."
    log "  Repository : ${REPO_URL}"
    log "  Branch     : ${BRANCH}"
    log "  Interval   : ${INTERVAL} minutes"
    log "  Jitter     : ${JITTER_ENABLED}"
    log "  Verify     : ${COMMIT_VERIFY}"
    log "  SSH policy : ${SSH_STRICT_HOST_KEY_CHECKING}"
    echo

    detect_os
    install_system_deps
    install_ansible
    install_sops_age
    validate_ssh_key
    clone_or_update_repo
    write_config
    run_initial_pull
    enable_timer
    print_success
}

main "$@"
