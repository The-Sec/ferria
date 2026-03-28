# TODO Next Session

## Validation
- Install ansible-lint in the active environment.
- Run: ansible-lint local.yml
- Run: ansible-playbook -i inventory/hosts.yml local.yml --check --diff --tags hostname,timezone,time_sync

## Configuration Follow-up
- Set per-host values for ferria_hostname in host_vars/<hostname>.yml.
- Confirm desired ferria_timezone values (global or per-host).
- Confirm NTP source policy for ferria_time_sync_sources (default global pools vs site-local time servers).

## Documentation Follow-up
- Add role variable documentation for:
  - ferria_hostname
  - ferria_timezone
  - ferria_time_sync_* variables
- Add operational notes for mixed distro behavior and service naming.

## Optional Hardening
- Add non-systemd guard/fallback behavior for validation tasks where needed.
- Add explicit role-level verify commands to operational docs.
