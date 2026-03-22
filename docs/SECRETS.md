# Secrets Management with SOPS and age

Ferria uses [SOPS](https://github.com/getsops/sops) with
[age](https://github.com/FiloSottile/age) to encrypt sensitive variables in your
Git repository. Secrets are encrypted at rest in Git and decrypted at runtime on
each machine using per-machine age private keys.

```
Your repository (Git — public or private)
├── group_vars/all.sops.yml       ← encrypted values (safe to commit)
└── host_vars/web01.sops.yml      ← encrypted values (safe to commit)

Each managed machine:
/etc/ferria/age-key.txt           ← private key  (NEVER commit this)

Runtime (pre_tasks in local.yml):
SOPS_AGE_KEY_FILE=/etc/ferria/age-key.txt
sops -d group_vars/all.sops.yml   → group_vars/all.yml
sops -d host_vars/web01.sops.yml  → host_vars/web01.yml
```

## Step 1: Generate an age key pair on each machine

On each Ferria-managed machine (as root):

```bash
# Generate the key pair
age-keygen -o /etc/ferria/age-key.txt
chmod 600 /etc/ferria/age-key.txt

# Display the public key (safe to share)
age-keygen -y /etc/ferria/age-key.txt
# → age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Record the public key for each machine — you'll add it to `.sops.yaml` next.

**Important:** The file at `/etc/ferria/age-key.txt` contains the private key.
It must never be committed to Git.

## Step 2: Add public keys to `.sops.yaml`

Edit `.sops.yaml` in your repository and add the public key for each machine
that needs to decrypt a given set of secrets:

```yaml
creation_rules:
  # group_vars secrets: decryptable by all machines
  - path_regex: group_vars/.*\.sops\.yml$
    age: >-
      age1abc123...   # web01
      age1def456...   # web02
      age1ghi789...   # db01

  # host_vars secrets: decryptable only by the specific host
  - path_regex: host_vars/web01\.sops\.yml$
    age: >-
      age1abc123...   # web01 only
```

Commit `.sops.yaml` to Git — it contains only public keys.

## Step 3: Create encrypted variable files

```bash
# Create a new encrypted file (opens your $EDITOR)
sops group_vars/all.sops.yml
```

Add your secrets as standard YAML:

```yaml
---
database_password: "s3cr3t"
api_key: "my-api-key"
smtp_password: "mail-password"
```

Save and close. SOPS encrypts the values (not the keys) and writes the
encrypted file. Commit the `.sops.yml` file to Git.

To edit an existing encrypted file:

```bash
sops group_vars/all.sops.yml
```

SOPS decrypts, opens your editor, and re-encrypts on save.

## Step 4: Reference secrets in roles

After decryption by `pre_tasks`, encrypted variables are available as standard
Ansible variables:

```yaml
# In a task:
- name: Configure database connection
  ansible.builtin.template:
    src: database.conf.j2
    dest: /etc/myapp/database.conf
    mode: "0600"

# In database.conf.j2:
password = {{ database_password }}
```

The `pre_tasks` in `local.yml` handles decryption automatically before any role
runs. The `no_log: true` directive prevents decrypted values from appearing in
Ansible output.

## Key rotation

**Adding a new machine:**

1. Generate an age key on the new machine (Step 1).
2. Add its public key to `.sops.yaml` under the relevant `creation_rules`.
3. Re-encrypt affected files:
   ```bash
   sops updatekeys group_vars/all.sops.yml
   # Or all sops files at once:
   find . -name '*.sops.yml' -exec sops updatekeys {} \;
   ```
4. Commit and push the updated `.sops.yaml` and re-encrypted files.

**Removing a machine's access:**

1. Remove the machine's public key from `.sops.yaml`.
2. Re-encrypt all affected files (`sops updatekeys`).
3. Commit and push.
4. Revoke the machine's SSH deploy key in your Git host settings.

The machine retains old ciphertext but cannot decrypt the new ciphertext without
its key being listed in `.sops.yaml`.

## Security notes

- `/etc/ferria/age-key.txt` should be `0600` owned by root.
- `/opt/ferria/repo/` (the working copy) should be `0700` — decrypted files are
  written here during `pre_tasks` and are readable only to root.
- The `pre_tasks` block in `local.yml` uses `no_log: true` to prevent decrypted
  secret values from appearing in Ansible's output or journald.
- When decommissioning a machine: remove its key from `.sops.yaml`, rotate
  all secrets it had access to, and revoke its SSH deploy key.
