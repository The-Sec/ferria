# group_vars

Variables in this directory are automatically loaded by Ansible based on
group membership defined in `inventory/hosts.yml`.

## Files

| File | Scope |
|---|---|
| `all.yml` | Every host — global defaults |
| `<groupname>.yml` | All hosts in `<groupname>` group |
| `<groupname>.sops.yml` | Encrypted secrets for the group (decrypted by pre_tasks) |

## Override hierarchy (highest to lowest precedence)

1. `host_vars/<hostname>.yml` — per-host overrides
2. `group_vars/<groupname>.yml` — group overrides
3. `group_vars/all.yml` — global defaults
4. `roles/<role>/defaults/main.yml` — role defaults

## Secrets

Create encrypted variable files with SOPS:

```bash
sops group_vars/webservers.sops.yml
```

The `pre_tasks` in `local.yml` decrypts `*.sops.yml` files at runtime using
the age key at `/etc/ferria/age-key.txt`. See `docs/SECRETS.md`.
