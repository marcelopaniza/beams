---
description: "Driver-only & maintenance ops: create, kick, lock/unlock, gc, cleanup-stale, transfer-driver, require-signatures, leave, members, init, test. No args lists subcommands."
argument-hint: "<subcommand> [args]   e.g. kick <beam> <who>, gc --dry-run all"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/admin.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/admin.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Report the output. Notes:
- Most subcommands are **driver-only** — they fail unless this terminal is the beam's driver.
- For `gc` and `cleanup-stale`, suggest a `--dry-run` first so the user sees what would be deleted.
- With no subcommand (or `help`), the script prints the list of available operations.
