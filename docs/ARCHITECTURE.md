# Ferria Architecture

## The Pull-Based Model

Ferria inverts the traditional push-based configuration management model. Instead
of a central controller pushing configuration to machines, each machine
autonomously pulls its own desired state from a shared Git repository and
converges toward it.

**Push-based (traditional):**
```
Controller → machine1
Controller → machine2
Controller → machine3
```

**Pull-based (Ferria):**
```
Git repository ← machine1 (ferria-agent)
Git repository ← machine2 (ferria-agent)
Git repository ← machine3 (ferria-agent)
```

This inversion has significant operational advantages:

- **Scales without a controller bottleneck.** Each machine does its own
  processing. Adding 100 machines increases load on your Git host only — not on
  any central automation system.
- **Controller failure doesn't affect machines.** There is no controller. If your
  Git host is unreachable, machines simply retry on the next tick. The last
  applied state remains in effect.
- **Network partitions are handled gracefully.** A machine that can't reach Git
  continues running with its last converged configuration until connectivity is
  restored.
- **Full audit trail via Git.** Every desired-state change is a commit with
  author, timestamp, and diff. `git log` is your complete change history.

## The Three Phases

### Phase 1: Bootstrap

Bootstrap is a one-shot operation performed manually (or via cloud-init) on a
fresh machine. It is a bash script rather than an Ansible playbook because
Ansible is not yet available at this stage.

Bootstrap sequence:
1. Detect OS and install system packages (`git`, `python3`, `python3-venv`)
2. Create a Python venv at `/opt/ferria/venv`; install Ansible with pinned
   versions (`ansible-core>=2.16,<2.18`, `ansible>=9.0,<11.0`)
3. Install SOPS and age for secret management
4. Validate the SSH deploy key; print instructions if absent
5. Clone the configuration repository to `/opt/ferria/repo`
6. Write `/etc/ferria/agent.conf` (configuration for the wrapper script)
7. Run the initial `ansible-pull` → installs the `ferria_agent` role, which
   writes the systemd service and timer unit files
8. Enable and start `ferria-agent.timer`

After bootstrap completes, the machine is self-managing.

### Phase 2: Reconciliation Loop

The reconciliation loop is the steady state of every Ferria-managed machine.

```
systemd timer (every N min)
        │
        ▼
ferria-agent.service (Type=oneshot)
        │
        ▼
/opt/ferria/ferria-wrapper.sh
        │
        ├── [optional] sleep random 0–N seconds (jitter)
        ├── [optional] git fetch + git verify-commit FETCH_HEAD
        ├── source /etc/ferria/agent.conf
        ├── activate Python venv
        └── ansible-pull -U <repo> -C <branch> -d /opt/ferria/repo \
                         -i inventory/hosts.yml [-o] [--clean] local.yml
                │
                ├── git fetch + checkout
                ├── pre_tasks: decrypt *.sops.yml files via SOPS
                ├── role: ferria_agent   (agent manages itself)
                └── role: <your roles>  (your infrastructure)
```

**Why systemd timer instead of cron?**

Systemd timers with `Type=oneshot` provide a critical safety property: only one
instance of the service can run at a time. If a convergence run takes longer than
the timer interval, the next tick is skipped rather than starting a concurrent
second run. This is the most common production failure with cron-based setups.

Additional benefits:
- `Persistent=true` catches up on missed ticks after downtime (e.g., reboots)
- `OnBootSec=2min` triggers a convergence run shortly after every reboot
- All output goes to journald with structured logging (unit name, timestamp, PID)
- `systemctl status ferria-agent.timer` shows next scheduled run and last result

### Phase 3: Convergent Playbooks

`local.yml` is the `ansible-pull` entrypoint. It runs `pre_tasks` to decrypt
secrets, then applies roles in order.

Roles follow the convergent pattern: each role checks whether the desired
end-state is already met before taking any action. See
[CONVERGENT-PATTERN.md](CONVERGENT-PATTERN.md).

## Self-Managing Agent

The `ferria_agent` role is applied on **every** reconciliation run. This means:

- Change `ferria_pull_interval_min` in `group_vars/all.yml` → commit → the agent
  rewrites its own timer unit and reloads systemd on the next pull.
- Update the wrapper script template → the agent overwrites its own
  `/opt/ferria/ferria-wrapper.sh`.
- Pin a new Ansible version → the agent upgrades itself inside the venv.

The agent bootstraps itself into place and then manages its own configuration
forward. Manual updates to managed machines are never required.

## Secret Management

Ferria uses SOPS (Secrets OPerationS) with age encryption.

```
Repository (Git — public or private)
├── group_vars/all.sops.yml       ← encrypted with ALL machines' age public keys
├── host_vars/web01.sops.yml      ← encrypted with web01's age public key only
└── ...

Each managed machine:
/etc/ferria/age-key.txt           ← age private key  (NEVER in Git)

Runtime (pre_tasks in local.yml):
  SOPS_AGE_KEY_FILE=/etc/ferria/age-key.txt
  sops -d group_vars/all.sops.yml → group_vars/all.yml   (in working copy)
  sops -d host_vars/web01.sops.yml → host_vars/web01.yml (in working copy)
```

Decrypted files are written to the local working copy at `/opt/ferria/repo/`
and are never committed to Git. See [SECRETS.md](SECRETS.md) for setup.

## Variable Precedence

Ansible's standard variable precedence applies (highest to lowest):

| Source | Scope |
|---|---|
| `host_vars/<hostname>.yml` | Per-host overrides (highest) |
| `group_vars/<groupname>.yml` | Group-specific values |
| `group_vars/all.yml` | Global defaults |
| `roles/<role>/defaults/main.yml` | Role defaults (lowest) |

Ferria does not add any additional layers beyond Ansible's standard hierarchy.

## ansible-pull vs ansible-playbook

Ferria uses `ansible-pull` rather than `ansible-playbook`. The key difference:
`ansible-pull` clones the repository to the target machine and runs the playbook
locally, enabling each machine to operate completely independently without a
controller. `ansible-playbook` requires a controller host with SSH access to all
targets.

Key `ansible-pull` flags used:

| Flag | Purpose |
|---|---|
| `-U <url>` | Repository URL |
| `-C <branch>` | Branch to track |
| `-d <path>` | Local directory for the clone |
| `-i inventory/hosts.yml` | Inventory file |
| `-o` | Only run if the repo has changed (skips playbook on unchanged commits) |
| `--clean` | Discard local modifications before pull |
