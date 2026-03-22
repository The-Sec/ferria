# Ferria

> Pull-based GitOps agent for bare metal and VMs

Ferria (from Latin *ferrum* — iron) is a lightweight pull-based GitOps agent
that runs on each machine (VM or bare metal), periodically fetches desired state
from a Git repository, and uses Ansible to converge the machine toward that
state. It follows the same reconciliation pattern as ArgoCD/Flux but for
traditional infrastructure — no Kubernetes required.

## How it works

```
┌─────────────────────────────────────────────────────────┐
│  Your Git repository (desired state)                    │
│  ┌───────────────────────────────────────────────────┐  │
│  │  group_vars/  host_vars/  roles/  local.yml       │  │
│  └───────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────┘
                            │  git pull (every N minutes)
             ┌──────────────┼──────────────┐
             │              │              │
             ▼              ▼              ▼
       ┌──────────┐   ┌──────────┐   ┌──────────┐
       │ machine1 │   │ machine2 │   │ machine3 │
       │  ferria  │   │  ferria  │   │  ferria  │
       │  agent   │   │  agent   │   │  agent   │
       └──────────┘   └──────────┘   └──────────┘
         Phase 2: each machine pulls and converges independently
```

**Phase 1 — Bootstrap (runs once).** Execute `bootstrap.sh` on a fresh machine.
It installs Ansible (in an isolated Python venv), SOPS, age, and git; clones
your configuration repository; and runs the initial `ansible-pull`, which
installs the Ferria systemd service and timer. The machine is then self-managing.

**Phase 2 — Reconciliation loop (runs continuously).** A systemd timer fires
every N minutes (default: 30). The associated `oneshot` service executes
`ansible-pull`, which fetches the latest commit, decrypts any SOPS-encrypted
variables, and runs the playbooks. The `oneshot` type prevents overlapping runs.
All output is captured in journald under the `ferria-agent` unit.

**Phase 3 — Convergent playbooks.** Roles follow a "check end-state first"
pattern — each role checks whether the desired state is already met; if so, it
does nothing. Only what is missing gets applied.

## Quick start

### 1. Set up your configuration repository

Fork or clone this template repository to your own Git account:

```bash
git clone git@github.com:The-Sec/ferria.git my-infra
cd my-infra
git remote set-url origin git@github.com:yourorg/my-infra.git
git push -u origin main
```

Edit `group_vars/all.yml` and set your repository URL:

```yaml
ferria_repo_url: "git@github.com:yourorg/my-infra.git"
```

Commit and push.

### 2. Generate a deploy SSH key

On the target machine (as root):

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "ferria@$(hostname -s)"
cat /root/.ssh/id_ed25519.pub
```

Add the public key as a **read-only deploy key** in your repository settings
(GitHub: Settings → Deploy keys → Add deploy key, uncheck "Allow write access").

### 3. Bootstrap the machine

```bash
# Download and run bootstrap.sh directly:
curl -fsSL https://raw.githubusercontent.com/yourorg/my-infra/main/bootstrap.sh \
  | bash -s -- -r git@github.com:yourorg/my-infra.git -b main -i 30

# Or with a local copy:
./bootstrap.sh -r git@github.com:yourorg/my-infra.git -b main -i 30
```

Ferria is now installed. It will pull and converge every 30 minutes.

## Configuration reference

All variables are defined in `group_vars/all.yml`. Override per-group in
`group_vars/<group>.yml` or per-host in `host_vars/<hostname>.yml`.

| Variable | Default | Description |
|---|---|---|
| `ferria_repo_url` | `git@github.com:CHANGEME/infra.git` | SSH URL of the configuration repository |
| `ferria_repo_branch` | `main` | Git branch to track |
| `ferria_repo_dest` | `/opt/ferria/repo` | Local path for the cloned repository |
| `ferria_pull_interval_min` | `30` | Reconciliation interval in minutes |
| `ferria_jitter_enabled` | `false` | Enable random delay before each pull |
| `ferria_jitter_max_sec` | `300` | Maximum jitter delay in seconds (0–N) |
| `ferria_commit_verify` | `false` | Require cryptographically signed commits |
| `ferria_venv_path` | `/opt/ferria/venv` | Python venv path |
| `ferria_age_key_path` | `/etc/ferria/age-key.txt` | Path to the age private key for SOPS |
| `ferria_log_level` | `info` | Log verbosity |
| `ferria_only_if_changed` | `true` | Skip playbook run if no new commits |
| `ferria_clean_checkout` | `true` | Discard local changes before each pull |

## Writing convergent roles

Ferria roles follow a "check end-state first, work backwards through the
dependency tree" pattern. See [`docs/CONVERGENT-PATTERN.md`](docs/CONVERGENT-PATTERN.md)
for the full guide, including a complete example role for an SMB/CIFS mount.

The `roles/example_convergent/` directory contains a working example role you
can copy as a starting point.

## Secrets management

Ferria uses [SOPS](https://github.com/getsops/sops) with
[age](https://github.com/FiloSottile/age) for encrypting sensitive variables.
Encrypted files use the naming convention `*.sops.yml` and are decrypted at
runtime by the `pre_tasks` block in `local.yml`.

See [`docs/SECRETS.md`](docs/SECRETS.md) for step-by-step setup.

## Operations

The `scripts/ferria-ctl.sh` script wraps common operations:

```bash
# Check timer status and last run result
./scripts/ferria-ctl.sh status

# Trigger an immediate convergence run (outside timer schedule)
./scripts/ferria-ctl.sh run

# Dry-run: show what would change without applying
./scripts/ferria-ctl.sh verify

# Follow logs in real time
./scripts/ferria-ctl.sh log-full

# Pause reconciliation (useful during maintenance)
./scripts/ferria-ctl.sh pause
./scripts/ferria-ctl.sh resume

# Show installed versions
./scripts/ferria-ctl.sh version
```

Direct systemd and journalctl commands also work:

```bash
systemctl status ferria-agent.timer
journalctl -u ferria-agent --since "1 hour ago"
systemctl start ferria-agent.service   # trigger immediate run
```

## Uninstalling

```bash
# Interactive (confirms before each destructive step)
./scripts/uninstall.sh

# Non-interactive, also remove /opt/ferria/ and /etc/ferria/
./scripts/uninstall.sh -y -a
```

This stops and disables the timer and service, removes the systemd unit files,
and optionally removes `/opt/ferria/` and `/etc/ferria/`. It does **not** undo
changes applied by your playbooks.

## Feature flags

### Thundering herd jitter (`-j` / `ferria_jitter_enabled`)

When many machines pull at the exact same interval, they can simultaneously hit
your Git host — a "thundering herd". Enabling jitter adds a random delay (0 to
`ferria_jitter_max_sec` seconds) before each pull. Enable when you have more
than ~20 machines.

### Commit verification (`-v` / `ferria_commit_verify`)

When enabled, Ferria verifies the cryptographic signature of the latest commit
before applying it. This ensures only commits signed by trusted keys can change
machine state. Requires commits to be signed with GPG or SSH keys. Disable
(the default) if your commits are not signed.

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for a detailed explanation
of the pull-based model, reconciliation loop, self-managing agent, and variable
precedence hierarchy.

## License

MIT. See [LICENSE](LICENSE).
