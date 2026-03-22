# host_vars

Place per-host variable overrides in this directory. Files named after the
hostname (or in a directory named after the hostname) are automatically loaded
by Ansible for that specific host.

## File naming

```
host_vars/
├── web01.yml          # Variables for host 'web01'
├── web01.sops.yml     # Encrypted secrets for 'web01' (decrypted at runtime)
├── db01/
│   ├── main.yml       # Directory form also works
│   └── secrets.sops.yml
```

## Usage

`host_vars/` overrides take the highest precedence in the variable hierarchy —
they override both `group_vars/<group>.yml` and `group_vars/all.yml`.

Use host_vars for:
- Machine-specific IP addresses or hostnames
- Hardware-specific tuning parameters
- Secrets that only one machine should decrypt (configure the relevant age key
  in `.sops.yaml` under a host-specific `path_regex`)

## Secrets

```bash
# Create an encrypted secrets file for a specific host
sops host_vars/web01.sops.yml
```

See `docs/SECRETS.md` for full setup instructions.
