# Work Log

## 2026-03-28

### Completed
- Reviewed legacy agent content under old/ and compared it with current Ferria agent architecture.
- Implemented Ferria agent hardening fixes:
  - Removed duplicate jitter execution from wrapper script so timer jitter is the single source of delay.
  - Switched age detection to command-based discovery (portable across distros and install paths).
  - Added missing standalone default for SSH StrictHostKeyChecking policy in ferria_agent role defaults.
- Started migration of selected legacy operational features into Ferria roles:
  - Added hostname role: roles/hostname
  - Added timezone role: roles/timezone
  - Added time sync role (chrony): roles/time_sync
- Wired new roles into local.yml in dependency order after ferria_agent.

### Notes
- ansible-lint is not installed in the current environment, so lint validation could not be executed yet.
- No disk/DRBD migration was included in this batch by design.
