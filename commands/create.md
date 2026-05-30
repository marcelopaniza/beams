---
description: "Create a new bus on the shared folder (idempotent — safe to re-run)."
argument-hint: "<bus-name>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/create.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/create.sh" "$(cat <<'BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Tell the user the bus is ready. If they want to receive messages on it, suggest `/buses:join <bus-name>`.
