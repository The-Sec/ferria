# Inventory

`hosts.yml` defines the machine inventory. In ansible-pull mode, each machine
only ever runs against `localhost`, so the inventory is mostly used for group
assignments that control which `group_vars/` are loaded.

## Groups

Add groups under `children:` in `hosts.yml`. Machines self-select by hostname —
add the host to the group to have that group's `group_vars/` applied to it.

```yaml
children:
  webservers:
    hosts:
      web01:
      web02:
  databases:
    hosts:
      db01:
```

Create matching variable files:
- `group_vars/webservers.yml` — applied to all webservers
- `group_vars/databases.yml` — applied to all database hosts

## Variable precedence

`host_vars/<hostname>.yml` > `group_vars/<group>.yml` > `group_vars/all.yml` > role defaults

See `group_vars/README.md` for details.
