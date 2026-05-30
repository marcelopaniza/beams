---
description: "Unsubscribe this session from a bus and remove its presence record."
argument-hint: "<bus-name>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/leave.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/leave.sh" "$(cat <<'BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm in one line.
