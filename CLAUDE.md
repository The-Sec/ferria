# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Ferria is

A pull-based GitOps agent for bare metal and VMs. Each managed machine runs a
systemd timer that periodically executes `ansible-pull`, fetching desired state
from this Git repository and converging the machine using Ansible roles. SOPS +
age handles secrets. No Kubernetes required.

## Common commands

```bash
# Lint all Ansible
ansible-lint local.yml

# Lint shell scripts
shellcheck bootstrap.sh scripts/*.sh

# Dry-run locally (check + diff, no changes applied), targeting a specific role
ansible-playbook -i inventory/hosts.yml local.yml --check --diff --tags ferria

# Create or edit an encrypted secrets file
sops group_vars/all.sops.yml

# Re-encrypt after adding/removing a machine's age public key
sops updatekeys group_vars/all.sops.yml

# Generate an age key on a managed machine (as root)
age-keygen -o /etc/ferria/age-key.txt

# On a managed machine — trigger an immediate convergence run
scripts/ferria-ctl.sh run

# On a managed machine — follow reconciliation logs live
scripts/ferria-ctl.sh log-full

# On a managed machine — dry-run (fetches latest, runs --check --diff)
scripts/ferria-ctl.sh verify
```

## Architecture

**Three phases:**

1. **Bootstrap** (`bootstrap.sh`): one-shot script run manually or via
   cloud-init. Installs Ansible in a venv at `/opt/ferria/venv`, SOPS, age, and
   git; clones the repo to `/opt/ferria/repo`; runs the initial `ansible-pull`
   which writes the systemd units; enables the timer.

2. **Reconciliation loop**: `ferria-agent.timer` fires every N minutes →
   `ferria-agent.service` (`Type=oneshot`, prevents concurrent runs) →
   `/opt/ferria/ferria-wrapper.sh` → `ansible-pull`.

3. **Convergent playbooks**: `local.yml` is the `ansible-pull` entrypoint.
   `pre_tasks` decrypts `*.sops.yml` files; roles run in order.

**Key paths on managed machines:**

| Path | Purpose |
|---|---|
| `/opt/ferria/venv/` | Isolated Python venv with Ansible |
| `/opt/ferria/repo/` | Local clone of this repository |
| `/opt/ferria/ferria-wrapper.sh` | Script executed by systemd on each tick |
| `/etc/ferria/agent.conf` | Runtime config (sourced by wrapper script) |
| `/etc/ferria/age-key.txt` | age private key for SOPS decryption |

**Secrets flow:** `*.sops.yml` files in `group_vars/` and `host_vars/` →
decrypted by `pre_tasks` in `local.yml` using `/etc/ferria/age-key.txt` →
written as `*.yml` in the working copy → available as Ansible variables →
`no_log: true` prevents logging of decrypted values.

**Self-managing agent:** `roles/ferria_agent/` is applied on every run. Changes
to timer interval, jitter, or the wrapper script template take effect
automatically on the next pull — no manual intervention on managed machines.

## Role writing conventions

- Roles follow the convergent pattern: check end-state first, walk the
  dependency tree backwards. See `docs/CONVERGENT-PATTERN.md` and
  `roles/example_convergent/` for a working example.
- Use fully qualified collection names on all tasks: `ansible.builtin.package`,
  not `package`.
- Every task needs a `name:`.
- Use handlers (not inline `notify` without a handler) for service restarts.
- Add `# noqa: ignore-errors` when `ignore_errors: true` is intentional (e.g.,
  the age package-manager fallback in `roles/ferria_agent/tasks/main.yml`).
- Every Jinja2 template must include a "Managed by Ferria" header comment.

**Variable precedence (high → low):**
`host_vars/<hostname>.yml` → `group_vars/<group>.yml` → `group_vars/all.yml` →
`roles/<role>/defaults/main.yml`

## Design decisions (do not deviate)

- **Systemd timer, not cron.** `Type=oneshot` prevents overlapping runs.
- **Python venv, not system pip.** Venv at `/opt/ferria/venv` isolates Ansible
  from OS Python packages.
- **SOPS decryption in `pre_tasks`, not a custom module.** Simple, debuggable,
  no custom plugins needed.
- **`ansible-pull -o` (only-if-changed).** Playbooks skip entirely when the Git
  repo has no new commits.
- **Config via `/etc/ferria/agent.conf`, not env vars.** File persists across
  reboots and is managed by the `ferria_agent` role itself.
