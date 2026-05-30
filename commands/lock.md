---
description: "Driver-only: lock a beam so only the manager can send. Members can still read."
argument-hint: "<beam> [reason...]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/lock.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/lock.sh" --from-stdin <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
```

Confirm the lock in one line. If the command failed (e.g. not the manager), surface the error verbatim.
