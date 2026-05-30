---
description: "Driver-only: transfer driver privileges to another member. Use --force to take over a bus whose driver is gone."
argument-hint: "<bus> <name-or-uuid> [--force]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/transfer-driver.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/transfer-driver.sh" "$(cat <<'BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm in one line: who's the new driver. If --force was used, mention briefly that the bus has been taken over (a one-off action, not a hostile one — the share is cooperative).
