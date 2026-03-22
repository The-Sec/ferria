# Writing Convergent Roles

## Philosophy

Ferria roles follow a "check end-state first, work backwards through the
dependency tree" pattern. Rather than issuing a sequence of commands, a
convergent role asks: *what is the desired end-state, and what is currently
missing from it?*

```
                  Desired end-state
                         │
                         ▼
            Is end-state already met?
           /                          \
         Yes                           No
          │                             │
      Report OK                 Walk dependency tree backwards:
       (no-op)                    ├── Is the service running?
                                  │     └── No → Is it configured?
                                  │               └── No → Is package installed?
                                  │                         └── No → Install it
                                  │               └── Yes → Deploy config
                                  │     └── Yes → Start service
                                  └── ...
```

The good news: **Ansible modules are already idempotent**. The
`ansible.builtin.package`, `ansible.builtin.template`, `ansible.builtin.file`,
and `ansible.builtin.service` modules all check current state before acting. A
role that uses only these built-in modules is automatically convergent.

The convergent *pattern* is about **structure** — organizing tasks in dependency
order so the relationship between layers is explicit and each task documents what
it is checking and why.

## When Built-In Idempotency Is Sufficient

For most roles, Ansible's built-in module idempotency is all you need:

```yaml
- name: Ensure nginx is installed
  ansible.builtin.package:
    name: nginx
    state: present
  # If already installed: reports OK. If missing: installs. No explicit check needed.

- name: Deploy nginx configuration
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
    mode: "0644"
  # Computes checksum of rendered template vs current file.
  # If equal: reports OK. If different: overwrites and notifies handler.
  notify: Reload nginx

- name: Ensure nginx is running and enabled
  ansible.builtin.service:
    name: nginx
    state: started
    enabled: true
  # If already running and enabled: reports OK.
```

## When You Need Explicit Checks

Shell commands (`ansible.builtin.command`, `ansible.builtin.shell`) are **not**
idempotent by default. Use `changed_when`, `failed_when`, and `when` to make
them convergent:

```yaml
- name: Check if application database is initialised
  ansible.builtin.stat:
    path: /var/lib/myapp/.initialized
  register: db_initialized

- name: Initialise application database
  ansible.builtin.command: myapp db init
  when: not db_initialized.stat.exists
  # Only runs if the sentinel file is absent.
  notify: Create initialisation sentinel

- name: Create initialisation sentinel
  ansible.builtin.file:
    path: /var/lib/myapp/.initialized
    state: touch
    mode: "0600"
  listen: Create initialisation sentinel
```

Key patterns:
- Use `ansible.builtin.stat` to check file/directory existence before acting
- Use `register` + `when` to gate actions on the observed current state
- Use `changed_when: false` for tasks that only *read* state (never change it)
- Use `failed_when` to define failure conditions for shell commands

## Complete Example: SMB/CIFS Mount

This example demonstrates the full backwards-checking pattern for a non-trivial
operation: mounting a network share.

The dependency tree:
```
Mount is present
  └── requires: mount point directory exists
  └── requires: credentials file exists
        └── requires: cifs-utils is installed
              └── requires: system dependencies
```

```yaml
---
# roles/cifs_mount/tasks/main.yml
# Convergent role: ensure a CIFS/SMB share is mounted.

# --- Layer 1: System dependencies ---
- name: Ensure cifs-utils is installed
  ansible.builtin.package:
    name: cifs-utils
    state: present

# --- Layer 2: Credentials ---
# The template module is idempotent: if the rendered content already matches
# the file on disk, no write is performed.
- name: Ensure credentials directory exists
  ansible.builtin.file:
    path: /etc/cifs
    state: directory
    owner: root
    group: root
    mode: "0700"

- name: Deploy CIFS credentials file
  ansible.builtin.template:
    src: cifs-credentials.j2
    dest: /etc/cifs/credentials
    owner: root
    group: root
    mode: "0600"

# --- Layer 3: Mount point ---
- name: Ensure mount point directory exists
  ansible.builtin.file:
    path: "{{ cifs_mount_point }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

# --- Layer 4: Check current mount state ---
# mountpoint returns 0 if mounted, 1 if not.
# changed_when: false → this task never reports a change (read-only check).
# failed_when: false  → rc=1 ("not mounted") is not an error here.
- name: Check if share is already mounted
  ansible.builtin.command: mountpoint -q "{{ cifs_mount_point }}"
  register: mount_check
  changed_when: false
  failed_when: false

# --- Layer 5: Mount only if not already mounted ---
- name: Mount CIFS share
  ansible.builtin.command: >
    mount -t cifs
    -o credentials=/etc/cifs/credentials,uid={{ cifs_uid }},gid={{ cifs_gid }}
    {{ cifs_share_path }} {{ cifs_mount_point }}
  when: mount_check.rc != 0
  # Only runs if mountpoint reported "not mounted".

# --- Layer 6: Persist mount across reboots ---
# ansible.builtin.mount with state=mounted handles both mounting and /etc/fstab.
# If the entry already exists in fstab and the share is mounted, this is a no-op.
- name: Ensure mount persists across reboots via fstab
  ansible.builtin.mount:
    path: "{{ cifs_mount_point }}"
    src: "{{ cifs_share_path }}"
    fstype: cifs
    opts: "credentials=/etc/cifs/credentials,uid={{ cifs_uid }},gid={{ cifs_gid }}"
    state: mounted

# --- Layer 7: Verify end-state ---
- name: Verify mount is accessible
  ansible.builtin.command: ls "{{ cifs_mount_point }}"
  changed_when: false
  failed_when: false
  register: mount_verify

- name: Warn if mount appears inaccessible
  ansible.builtin.debug:
    msg: "WARNING: mount point appears empty or inaccessible — check share path and credentials"
  when: mount_verify.rc != 0 or mount_verify.stdout == ""
```

## Convergent Role Checklist

When writing a new role:

1. **Map the dependency tree.** What does the desired end-state require? What
   does each dependency require?
2. **Order tasks by dependency layer** — prerequisites first, end-state last.
3. **Use built-in modules** (`package`, `template`, `file`, `service`) wherever
   possible — they handle idempotency automatically.
4. **For shell commands**: add `changed_when` and `when` clauses. Gate actions
   on state checks with `register`.
5. **Add a verification step** at the end to confirm the end-state was reached
   (`changed_when: false`).
6. **Use handlers** for actions that should only happen when something actually
   changes (restarting services, reloading daemons).
7. **Tag every task** so operators can run specific layers without the full
   playbook (`ansible-pull ... --tags nginx`).
8. **Add a "Managed by Ferria" header** to every template file so operators know
   not to edit it manually.
